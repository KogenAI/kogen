module clean_candidate_verification {
  // Versions abstract exact trees, not ignored workspace files.
  var s: { candidate: int, tested: int, reviewed: int, clean: bool, stopped: bool, committed: bool }
  action init = s' = { candidate: 0, tested: -1, reviewed: -1, clean: false, stopped: false, committed: false }
  action edit = all { not(s.stopped), not(s.committed), s' = { ...s, candidate: s.candidate + 1 } }
  action verify = all {
    not(s.stopped), not(s.committed),
    nondet generated = Set(true, false).oneOf()
    nondet needsIgnored = Set(true, false).oneOf()
    nondet stable = Set(true, false).oneOf()
    val green = (not(needsIgnored) or generated) and stable
    s' = { ...s, tested: if (green) s.candidate else -1, clean: green }
  }
  action approve = all { not(s.stopped), not(s.committed), s' = { ...s, reviewed: s.candidate } }
  action stop = all { not(s.committed), s' = { ...s, stopped: true } }
  action resume = all { s.stopped, s' = { ...s, stopped: false } }
  // Legacy workspace-only evidence can be loaded but never authorizes commit.
  action legacy = all { not(s.committed), s' = { ...s, tested: s.candidate, clean: false } }
  action commit = all { not(s.stopped), s.clean, s.tested == s.candidate, s.reviewed == s.candidate, s' = { ...s, committed: true } }
  action idle = s' = s
  action step = any { edit, verify, approve, stop, resume, legacy, commit, idle }
  val CleanExactCommit = s.committed implies (s.clean and s.tested == s.candidate and s.reviewed == s.candidate)
}
