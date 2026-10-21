module cache_capability_fallback {
  var s: { phase: str, unsupported: bool, retries: int, elapsed: int, eligible: bool, controls: bool, saved: bool, semantic: int, failedUnknown: bool }
  action init = s' = { phase: "ready", unsupported: false, retries: 0, elapsed: 0, eligible: false, controls: true, saved: false, semantic: 1, failedUnknown: true }
  action request = all { s.phase == "ready", s.elapsed < 4, s' = { ...s, phase: "waiting", controls: not(s.unsupported) } }
  action refuse = {
    nondet definite = Set(true, false).oneOf()
    all { s.phase == "waiting", s' = { ...s, phase: "refused", eligible: definite and s.controls, failedUnknown: true } }
  }
  action fallback = all { s.phase == "refused", s.eligible, not(s.unsupported), s.elapsed < 4, s' = { ...s, phase: "waiting", unsupported: true, retries: s.retries + 1, controls: false } }
  action complete = all { s.phase == "waiting", s.elapsed < 4, s' = { ...s, phase: "ready" } }
  action stop = all { s.phase == "ready", s' = { ...s, phase: "stopped", saved: s.unsupported } }
  action resume = all { s.phase == "stopped", s' = { ...s, phase: "ready", unsupported: s.saved } }
  action tick = all { s.elapsed < 4, s' = { ...s, elapsed: s.elapsed + 1, phase: if (s.elapsed + 1 == 4) "expired" else s.phase } }
  action idle = s' = s
  action step = any { request, refuse, fallback, complete, stop, resume, tick, idle }
  val Bounded = s.retries <= 1 and s.elapsed <= 4 and (s.elapsed == 4 implies s.phase == "expired")
  val SafeFallback = s.semantic == 1 and s.failedUnknown and (s.retries > 0 implies s.unsupported)
  val Sticky = (s.unsupported implies not(s.controls)) and (s.phase == "stopped" implies s.saved == s.unsupported)
}
