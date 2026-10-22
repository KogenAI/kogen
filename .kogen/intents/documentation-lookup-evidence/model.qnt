module documentation_lookup_evidence {
  type S = { docs: int, probes: int, records: int, events: int, progress: int, lines: int, published: bool, inspected: bool, adopted: bool }
  var s: S
  action init = s' = { docs: 0, probes: 0, records: 0, events: 0, progress: 0, lines: 0, published: false, inspected: false, adopted: false }
  action read = all { not(s.published), s' = { ...s, inspected: true } }
  action lookup = all { not(s.published), s.docs < 4, s' = { ...s, docs: s.docs + 1, records: s.records + 1, events: s.events + 1, progress: s.progress + 1 } }
  action probe = all { not(s.published), s.probes < 2, s' = { ...s, probes: s.probes + 1 } }
  action citeLine = all { not(s.published), s.lines < s.docs, s' = { ...s, lines: s.lines + 1 } }
  action adopt = all { not(s.published), s' = { ...s, adopted: true } }
  action publish = all {
    not(s.published),
    s.inspected,
    not(s.adopted),
    s.records == s.docs,
    s.events == s.docs,
    s.progress == s.docs,
    s' = { ...s, published: true }
  }
  action idle = s' = s
  action step = any { read, lookup, probe, citeLine, adopt, publish, idle }
  val RecordsMatchCalls = s.records == s.docs and s.events == s.docs and s.progress == s.docs and s.lines <= s.docs
  val PublishedKeepsEvidence = s.published implies (s.inspected and not(s.adopted) and s.records == s.docs and s.lines <= s.docs)
}
