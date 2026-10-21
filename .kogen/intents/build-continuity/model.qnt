module build_continuity {
  var s: { owner: str, stopped: bool, pending: bool, safe: bool, window: int, archived: int, generation: int, authority: int, source: int, candidate: int, tested: int, reviewed: int, finding: bool, committed: bool }
  action init = s' = { owner: "builder", stopped: false, pending: false, safe: true, window: 2, archived: 0, generation: 0, authority: 1, source: 1, candidate: 0, tested: -1, reviewed: -1, finding: false, committed: false }
  action issue = all { not(s.stopped), not(s.pending), not(s.committed), s.window <= 6, s' = { ...s, pending: true } }
  action complete = all { s.pending, not(s.stopped), s' = { ...s, pending: false, window: s.window + 2, candidate: s.candidate + 1, tested: -1, reviewed: -1 } }
  action reset = all { not(s.pending), not(s.stopped), not(s.committed), s.window > 6, s' = { ...s, archived: s.archived + s.window, window: 2, generation: s.generation + 1 } }
  action stop = all { not(s.committed), s' = { ...s, stopped: true } }
  action drift = all { s.stopped, s' = { ...s, safe: false } }
  action resume = all { s.stopped, s.safe, not(s.pending), s' = { ...s, stopped: false } }
  action verify = all { not(s.stopped), not(s.pending), s' = { ...s, tested: s.candidate } }
  action review = all { not(s.stopped), s.owner == "builder", s.tested == s.candidate, s' = { ...s, owner: "reviewer", window: 2, finding: true } }
  action clear = all { not(s.stopped), s.owner == "reviewer", not(s.pending), s.tested == s.candidate, s' = { ...s, reviewed: s.candidate, finding: false } }
  action commit = all { not(s.stopped), not(s.pending), s.safe, s.owner == "reviewer", not(s.finding), s.tested == s.candidate, s.reviewed == s.candidate, s' = { ...s, committed: true } }
  action idle = s' = s
  action step = any { issue, complete, reset, stop, drift, resume, verify, review, clear, commit, idle }
  val Authority = s.authority == 1 and s.source == 1
  val Budget = s.window <= 8 and s.archived >= 0 and s.generation >= 0
  val ExactCommit = s.committed implies (s.safe and not(s.pending) and s.owner == "reviewer" and not(s.finding) and s.tested == s.candidate and s.reviewed == s.candidate)
  val Safety = Authority and Budget and ExactCommit
}
