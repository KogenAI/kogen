module stages {
  var s: {completed: int, cand: int, full: int, reviewed: int, phase: str, stopped: bool, intact: bool, commits: int}
  action init = s' = {completed: 0, cand: 0, full: -1, reviewed: -1, phase: "stage", stopped: false, intact: true, commits: 0}
  action edit = all {
    not(s.stopped), s.phase.in(Set("stage", "final", "review")),
    s' = s.with("cand", s.cand + 1).with("full", -1).with("reviewed", -1)
  }
  action stageGate = all {
    not(s.stopped), s.phase == "stage", s.intact,
    nondet green = Set(true, false).oneOf()
    s' = if (green) s.with("completed", s.completed + 1).with("phase", if (s.completed == 1) "final" else "stage") else s
  }
  action finalGate = all {
    not(s.stopped), s.phase == "final", s.intact,
    nondet green = Set(true, false).oneOf()
    s' = if (green) s.with("full", s.cand).with("phase", "review") else s.with("full", -1)
  }
  action review = all {
    not(s.stopped), s.phase == "review", s.intact,
    s' = if (s.full == s.cand) s.with("reviewed", s.cand).with("phase", "commit") else s.with("phase", "final")
  }
  action stop = all {
    s.phase != "landed", not(s.stopped), s' = s.with("stopped", true)
  }
  action drift = all {
    s.stopped, s' = s.with("intact", false)
  }
  action resume = all {
    s.stopped, s.intact, s' = s.with("stopped", false)
  }
  action commit = all {
    not(s.stopped), s.intact, s.phase == "commit", s.full == s.cand, s.reviewed == s.cand,
    s' = s.with("commits", 1).with("phase", "landed")
  }
  action step = any {edit, stageGate, finalGate, review, stop, drift, resume, commit}
  val Ordered = s.completed >= 0 and s.completed <= 2
  val WholeDelivery = s.commits == 0 or (s.completed == 2 and s.full == s.cand and s.reviewed == s.cand and s.phase == "landed")
  val NoPartialCommit = s.completed == 2 or s.commits == 0
  val SafeResume = s.intact or s.stopped
  val Safety = Ordered and WholeDelivery and NoPartialCommit and SafeResume

}
