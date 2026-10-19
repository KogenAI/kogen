module clean_readiness_parity {
  var s: { input: int, proof: int, clean: bool, red: bool, inspected: bool, published: bool, reused: bool, original: bool, warmth: int }
  action init = s' = { input: 0, proof: -1, clean: false, red: false, inspected: false, published: false, reused: false, original: false, warmth: 0 }
  val exact = s.clean and s.proof == s.input
  action change = s' = { ...s, input: s.input + 1, published: false, reused: false }
  action warm = s' = { ...s, warmth: s.warmth + 1 }
  action legacy = all { not(s.published), s' = { ...s, proof: s.input, clean: false, reused: false } }
  action check = all {
    not(s.published),
    nondet red = Set(true, false).oneOf()
    s' = { ...s, proof: s.input, clean: true, red: red, inspected: false, reused: false }
  }
  action inspect = all { exact, s.red, s' = { ...s, inspected: true } }
  action reuse = all { exact, s' = { ...s, reused: true } }
  action retainOriginal = all { exact, s' = { ...s, original: true } }
  action publish = all { exact, not(s.red) or s.inspected, s' = { ...s, published: true } }
  action idle = s' = s
  action step = any { change, warm, legacy, check, inspect, reuse, retainOriginal, publish, idle }
  val SafePublication = s.published implies (exact and (not(s.red) or s.inspected))
  val ExactReuse = s.reused implies exact
  val HonestOriginal = (s.original and not(s.clean)) implies not(s.published)
}
