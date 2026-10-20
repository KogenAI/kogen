module build_diagnostic_context {
  var s: { phase: str, external: int, captured: int, conversation: int, valid: bool, reads: int, requests: int, protected: bool, green: bool, reviewed: bool, committed: bool }
  action init = s' = { phase: "new", external: 1, captured: -1, conversation: -1, valid: false, reads: 0, requests: 0, protected: true, green: false, reviewed: false, committed: false }
  action ingest = {
    nondet ok = Set(true, false).oneOf()
    all { s.phase == "new", s' = { ...s, phase: if (ok) "ready" else "rejected", valid: ok, reads: 1, captured: if (ok) s.external else -1 } }
  }
  action start = all { s.phase == "ready", s.valid, s' = { ...s, phase: "active", conversation: s.captured, requests: s.requests + 1 } }
  action externalChange = s' = { ...s, external: s.external + 1 }
  action stop = all { s.phase == "active", s' = { ...s, phase: "stopped" } }
  action resume = all { s.phase == "stopped", s' = { ...s, phase: "active", requests: s.requests + 1 } }
  action protectedAttempt = all { s.phase == "active", s' = s }
  action verify = all { s.phase == "active", s' = { ...s, green: true } }
  action review = all { s.phase == "active", s.green, s' = { ...s, reviewed: true } }
  action commit = all { s.phase == "active", s.green, s.reviewed, s.protected, s' = { ...s, phase: "landed", committed: true } }
  action idle = s' = s
  action step = any { ingest, start, externalChange, stop, resume, protectedAttempt, verify, review, commit, idle }
  val Frozen = Set("active", "stopped", "landed").contains(s.phase) implies (s.valid and s.reads == 1 and s.conversation == s.captured)
  val Guarded = s.protected and (s.phase == "rejected" implies s.requests == 0) and (s.committed implies (s.green and s.reviewed))
}
