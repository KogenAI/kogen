module terminal_protocol_compatibility {
  var s: { phase: str, items: Set[int], pending: Set[int], invalid: bool, failed: bool, accepted: bool, retained: bool, beforeItems: Set[int], beforePending: Set[int] }
  action init = s' = { phase: "stream", items: Set(), pending: Set(), invalid: false, failed: false, accepted: false, retained: false, beforeItems: Set(), beforePending: Set() }
  action added = {
    nondet i = Set(0, 1, 2).oneOf()
    all { s.phase == "stream", s' = { ...s, pending: s.pending.union(Set(i)) } }
  }
  action done = {
    nondet i = Set(0, 1, 2).oneOf()
    all { s.phase == "stream", s' = { ...s, items: s.items.union(Set(i)), pending: s.pending.exclude(Set(i)) } }
  }
  action invalid = all { s.phase == "stream", s' = { ...s, invalid: true } }
  action failure = all { s.phase == "stream", s' = { ...s, failed: true } }
  action complete = {
    nondet mode = Set("empty", "omitted", "nonempty").oneOf()
    nondet envelopeValid = Set(true, false).oneOf()
    nondet finalItems = Set(Set(0), Set(0, 1), Set(0, 1, 2)).oneOf()
    val replacement = mode == "nonempty"
    val items = if (replacement) finalItems else s.items
    val pending = if (replacement) Set() else s.pending
    val coverage = not(replacement) or s.items.union(s.pending).subseteq(items)
    val valid = not(s.invalid) and envelopeValid and coverage
    val contiguous = items == Set(0) or items == Set(0, 1) or items == Set(0, 1, 2)
    all { s.phase == "stream", s' = { ...s, phase: "terminal", items: items, pending: pending, invalid: not(valid), accepted: valid and not(s.failed) and contiguous and pending == Set(), retained: mode == "empty", beforeItems: s.items, beforePending: s.pending } }
  }
  action idle = s' = s
  action step = any { added, done, invalid, failure, complete, idle }
  val Retained = s.retained implies (s.items == s.beforeItems and s.pending == s.beforePending)
  val SafeAcceptance = s.accepted implies (s.phase == "terminal" and not(s.invalid) and not(s.failed) and s.pending == Set() and (s.items == Set(0) or s.items == Set(0, 1) or s.items == Set(0, 1, 2)))
}
