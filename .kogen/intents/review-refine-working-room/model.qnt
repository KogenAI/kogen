module working_room {
  var s: { phase: str, pending: bool, stopped: bool, safe: bool, sourceInline: bool, window: int, archives: int, authority: int, proposals: int, observed: int, candidate: int, tested: int, reviewed: int, blocker: bool, committed: bool, published: bool }
  action init = s' = { phase: "review", pending: false, stopped: false, safe: true, sourceInline: true, window: 4, archives: 0, authority: 1, proposals: 0, observed: -1, candidate: 0, tested: 0, reviewed: -1, blocker: true, committed: false, published: false }
  action chooseRefine = all { s.archives == 0, not(s.pending), s.candidate == 0, not(s.committed), not(s.published), s' = { ...s, phase: "refine", sourceInline: false } }
  action issue = all { not(s.pending), not(s.stopped), s.safe, s.window <= 6, not(s.committed), not(s.published), s' = { ...s, pending: true } }
  action complete = all { s.pending, s' = { ...s, pending: false, window: s.window + 2 } }
  action reset = all { not(s.pending), not(s.stopped), s.safe, s.window > 6, s' = { ...s, sourceInline: false, window: 3, archives: s.archives + 1 } }
  action refuse = all { not(s.pending), s.window > 6, s' = { ...s, stopped: true } }
  action damage = all { s.archives > 0, not(s.pending), not(s.committed), not(s.published), s' = { ...s, safe: false, stopped: true } }
  action edit = all { not(s.pending), not(s.stopped), not(s.committed), not(s.published), s' = { ...s, candidate: s.candidate + 1, proposals: s.proposals + 1, observed: -1, tested: -1, reviewed: -1 } }
  action verify = all { not(s.pending), not(s.stopped), s.safe, s' = { ...s, tested: s.candidate, observed: s.proposals } }
  action approve = all { s.phase == "review", not(s.pending), not(s.stopped), s.safe, s' = { ...s, reviewed: s.candidate, blocker: false } }
  action commit = all { s.phase == "review", not(s.pending), not(s.stopped), s.safe, not(s.blocker), s.tested == s.candidate, s.reviewed == s.candidate, s' = { ...s, committed: true } }
  action publish = all { s.phase == "refine", not(s.pending), not(s.stopped), s.safe, s.tested == s.candidate, s.observed == s.proposals, s' = { ...s, published: true } }
  action idle = s' = s
  action step = any { chooseRefine, issue, complete, reset, refuse, damage, edit, verify, approve, commit, publish, idle }
  val Authority = s.authority == 1
  val BoundedSend = s.pending implies (s.window <= 6 and s.safe and not(s.stopped))
  val ExactCompletion = (s.committed implies (s.safe and s.tested == s.candidate and s.reviewed == s.candidate and not(s.blocker))) and (s.published implies (s.safe and s.tested == s.candidate and s.observed == s.proposals))
}
