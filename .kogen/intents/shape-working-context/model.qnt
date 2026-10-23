module shape_working_context {
  var s: { active: int, archived: int, completed: int, pending: bool, window: int, sentBytes: int, stopped: bool, authority: int, candidate: int, checked: int, observed: bool, published: bool }
  action init = s' = { active: 0, archived: 0, completed: 0, pending: false, window: 0, sentBytes: 0, stopped: false, authority: 1, candidate: 0, checked: -1, observed: false, published: false }
  val requestBytes = 3 + s.active * 2
  action issue = all { not(s.stopped), not(s.published), not(s.pending), requestBytes <= 8, s' = { ...s, pending: true, sentBytes: requestBytes } }
  action complete = all { s.pending, not(s.stopped), s' = { ...s, pending: false, active: s.active + 1, completed: s.completed + 1 } }
  action reset = all { not(s.pending), not(s.stopped), not(s.published), requestBytes > 8, s.active > 1, s' = { ...s, active: 1, archived: s.archived + s.active - 1, window: s.window + 1 } }
  action stop = all { not(s.pending), not(s.published), s' = { ...s, stopped: true } }
  action propose = all { not(s.pending), not(s.stopped), not(s.published), s' = { ...s, candidate: s.candidate + 1, checked: -1, observed: false } }
  action check = all { not(s.pending), not(s.stopped), not(s.published), s' = { ...s, checked: s.candidate, observed: false } }
  action acknowledge = all { s.checked == s.candidate, not(s.stopped), not(s.published), s' = { ...s, observed: true } }
  action publish = all { not(s.pending), not(s.stopped), not(s.published), s.checked == s.candidate, s.observed, s' = { ...s, published: true } }
  action idle = s' = s
  action step = any { issue, complete, reset, stop, propose, check, acknowledge, publish, idle }
  val Custody = s.authority == 1 and s.active + s.archived == s.completed and s.archived >= 0
  val Guard = s.sentBytes <= 8 and (s.pending implies not(s.published))
  val Publication = s.published implies (s.checked == s.candidate and s.observed and not(s.pending))
}
