module native_image_evidence {
  var s: { path: int, frozen: int, replay: int, pending: bool, delivered: bool, observed: bool, stopped: bool, safe: bool, owner: str, ownRead: bool, green: bool, reviewed: bool, committed: bool }
  action init = s' = { path: 1, frozen: -1, replay: -1, pending: false, delivered: false, observed: false, stopped: false, safe: true, owner: "build", ownRead: false, green: false, reviewed: false, committed: false }
  action read = all { not(s.pending), not(s.stopped), not(s.committed), s' = { ...s, frozen: s.path, replay: s.path, delivered: false, observed: false, ownRead: true } }
  action changePath = s' = { ...s, path: s.path + 1 }
  action request = all { not(s.stopped), not(s.pending), s.ownRead, not(s.committed), s' = { ...s, pending: true } }
  action complete = all { s.pending, s' = { ...s, pending: false, delivered: true } }
  action rejectRequest = all { s.pending, s' = { ...s, pending: false, stopped: true } }
  action observe = all { s.delivered, not(s.stopped), s' = { ...s, observed: true } }
  action stop = all { not(s.pending), not(s.committed), s' = { ...s, stopped: true } }
  action unsafe = all { s.stopped, s' = { ...s, safe: false } }
  action resume = all { s.stopped, s.safe, not(s.pending), s' = { ...s, stopped: false } }
  action window = all { not(s.pending), not(s.stopped), s' = s }
  action verify = all { not(s.stopped), not(s.pending), s' = { ...s, green: true } }
  action review = all { s.owner == "build", s.green, not(s.pending), not(s.stopped), s' = { ...s, owner: "review", ownRead: false, frozen: -1, replay: -1, delivered: false, observed: false } }
  action approve = all { s.owner == "review", s.ownRead, s.observed, s.green, not(s.stopped), s' = { ...s, reviewed: true } }
  action commit = all { s.safe, not(s.stopped), not(s.pending), s.green, s.reviewed, s.owner == "review", s' = { ...s, committed: true } }
  action idle = s' = s
  action step = any { read, changePath, request, complete, rejectRequest, observe, stop, unsafe, resume, window, verify, review, approve, commit, idle }
  val Frozen = s.replay == s.frozen
  val Honest = s.observed implies (s.delivered and s.ownRead)
  val ExactCommit = s.committed implies (s.safe and s.green and s.reviewed and s.owner == "review" and not(s.pending))
  val Safety = Frozen and Honest and ExactCommit
}
