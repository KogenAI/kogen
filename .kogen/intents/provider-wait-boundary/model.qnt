module boundary {
  var s: { elapsed: int, phase: str, active: bool, valid: bool, success: bool, cancelled: bool }
  action init = s' = { elapsed: 0, phase: "credentials", active: false, valid: false, success: false, cancelled: false }
  val live = Set("credentials", "refresh", "stream", "backoff").contains(s.phase)
  action tick = all { live, s.elapsed < 6, s' = if (s.elapsed + 1 == 6) { ...s, elapsed: 6, phase: "expired", active: false } else { ...s, elapsed: s.elapsed + 1 } }
  action request = all { live, s.elapsed < 6, s' = { ...s, phase: "stream", active: true } }
  action refresh = all { live, s.elapsed < 6, s' = { ...s, phase: "refresh", active: true } }
  action retry = all { s.phase == "stream", s.elapsed < 6, s' = { ...s, phase: "backoff", active: false } }
  action bytes = all { s.phase == "stream", s' = s }
  action terminal = { nondet valid = Set(true, false).oneOf()
    all { s.phase == "stream", s.elapsed < 6, s' = { ...s, phase: if (valid) "done" else "failed", active: false, valid: valid, success: valid } }
  }
  action cancel = all { live, s' = { ...s, phase: "cancelled", active: false, cancelled: true } }
  action idle = all { not(live), s' = s }
  action step = any { tick, request, refresh, retry, bytes, terminal, cancel, idle }
  val Bounded = s.elapsed <= 6 and (s.elapsed == 6 implies (s.phase == "expired" and not(s.active)))
  val SafeResult = (s.success implies (s.valid and s.elapsed < 6)) and (s.cancelled implies not(s.active))
}
