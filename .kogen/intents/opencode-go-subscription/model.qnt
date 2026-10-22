module opencode_go_subscription {
  var s: { credential: bool, owner: str, session: int, saved: int, stopped: bool, pending: bool, provider: str, replay: Set[int], builder: Set[int], unsupported: bool, controls: bool, retries: int }
  action init = s' = { credential: false, owner: "build", session: 1, saved: 1, stopped: false, pending: false, provider: "opencode-go", replay: Set(), builder: Set(), unsupported: false, controls: true, retries: 0 }
  action login = s' = { ...s, credential: true }
  action invalidLogin = s' = s
  action request = all { s.credential, not(s.stopped), not(s.pending), s' = { ...s, pending: true, controls: not(s.unsupported) } }
  action complete = all { s.pending, s' = { ...s, pending: false, replay: s.replay.union(Set(s.session)) } }
  action refusal = all { s.pending, s' = { ...s, pending: false, stopped: true } }
  action rejectControl = all { s.pending, not(s.unsupported), s' = { ...s, unsupported: true, controls: false, retries: s.retries + 1 } }
  action stop = all { not(s.pending), s' = { ...s, stopped: true, saved: s.session } }
  action resume = all { s.stopped, not(s.pending), s' = { ...s, stopped: false } }
  action review = all { not(s.stopped), not(s.pending), s.owner == "build", s' = { ...s, owner: "review", session: 2, saved: 2, builder: s.replay, replay: Set(), unsupported: false, controls: true, retries: 0 } }
  action idle = s' = s
  action step = any { login, invalidLogin, request, complete, refusal, rejectControl, stop, resume, review, idle }
  val NoFallback = s.provider == "opencode-go"
  val Independent = s.owner == "review" implies s.replay.forall(x => x == 2) and s.builder.forall(x => x == 1)
  val Compatible = s.retries <= 1 and (s.unsupported implies not(s.controls)) and (s.stopped implies s.session == s.saved)
}
