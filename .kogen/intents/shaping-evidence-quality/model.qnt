module evidence_model {
  var s: { candidate: int, proof: int, declared: bool, satisfied: bool, checked: bool, red: bool, ack: bool, published: bool }
  action init = s' = { candidate: 0, proof: -1, declared: false, satisfied: false, checked: false, red: false, ack: false, published: false }
  action change = { nondet needs = Set(true, false).oneOf()
    s' = { ...s, candidate: s.candidate + 1, declared: needs, checked: false, ack: false, published: false }
  }
  action observe = { nondet ok = Set(true, false).oneOf()
    nondet failed = Set(true, false).oneOf()
    s' = { ...s, proof: s.candidate, satisfied: ok, checked: true, red: failed, ack: false, published: false }
  }
  val exact = s.checked and s.proof == s.candidate and (not(s.declared) or s.satisfied)
  action acknowledge = all { exact, s.red, s' = { ...s, ack: true } }
  action publish = all { exact, not(s.red) or s.ack, s' = { ...s, published: true } }
  action idle = s' = s
  action step = any { change, observe, acknowledge, publish, idle }
  val ExactObligations = s.published implies exact
  val RedIsNotWaiver = (s.published and s.red) implies (s.ack and (not(s.declared) or s.satisfied))
}
