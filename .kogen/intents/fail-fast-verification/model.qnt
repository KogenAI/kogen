module fail_fast_verification {
  var s: { candidate: int, tested: int, done: int, red: bool, skipped: int, clean: bool, stopped: bool, approved: bool, committed: bool }
  action init = s' = { candidate: 0, tested: -1, done: 0, red: false, skipped: 0, clean: false, stopped: false, approved: false, committed: false }
  action begin = all { not(s.committed), not(s.stopped), s' = { ...s, tested: s.candidate, done: 0, red: false, skipped: 0, clean: true, approved: false } }
  action execute = all {
    not(s.stopped), not(s.committed), s.tested == s.candidate, s.clean, not(s.red), s.done < 3,
    nondet ok = Set(true, false).oneOf()
    s' = { ...s, done: s.done + 1, red: not(ok), skipped: if (ok) 0 else 2 - s.done }
  }
  val complete = s.tested == s.candidate and s.clean and s.done == 3 and not(s.red) and s.skipped == 0
  action edit = all { not(s.committed), not(s.stopped), s' = { ...s, candidate: s.candidate + 1, approved: false } }
  action mutate = all { not(s.committed), s' = { ...s, clean: false, approved: false } }
  action approve = all { not(s.stopped), complete, s' = { ...s, approved: true } }
  action commit = all { not(s.stopped), not(s.committed), complete, s.approved, s' = { ...s, committed: true } }
  action stop = all { not(s.committed), s' = { ...s, stopped: true } }
  action resume = all { s.stopped, s' = { ...s, stopped: false } }
  action idle = s' = s
  action step = any { begin, execute, edit, mutate, approve, commit, stop, resume, idle }
  val RedStops = s.red implies s.done + s.skipped == 3
  val GreenRequiresAll = (s.approved or s.committed) implies complete
  val Safety = RedStops and GreenRequiresAll
}
