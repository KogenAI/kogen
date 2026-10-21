module prompt_cache_reuse_and_usage {
  var s: { owner: str, baseline: int, comparison: int, serial: int, stopped: bool, saved: int, transcript: int, savedTranscript: int, unsupported: bool, fallbacks: int, seen: Set[int], input: int, cached: int, unknown: int, candidate: int, verified: int, reviewed: int, committed: bool }
  action init = s' = { owner: "build", baseline: -1, comparison: -1, serial: 0, stopped: false, saved: -1, transcript: 0, savedTranscript: 0, unsupported: false, fallbacks: 0, seen: Set(), input: 0, cached: 0, unknown: 0, candidate: 0, verified: -1, reviewed: -1, committed: false }
  action complete = all { not(s.stopped), not(s.committed), s' = { ...s, comparison: s.baseline, baseline: s.serial, serial: s.serial + 1, transcript: s.transcript + 1, seen: s.seen.union(Set(s.serial)), input: s.input + 10, cached: s.cached + 2 } }
  action duplicate = all { s.seen.size() > 0, s' = s }
  action failure = all { not(s.stopped), not(s.committed), s' = { ...s, unknown: s.unknown + 1 } }
  action rejectOption = all { not(s.stopped), not(s.unsupported), not(s.committed), s' = { ...s, unsupported: true, fallbacks: s.fallbacks + 1, unknown: s.unknown + 1 } }
  action stop = all { not(s.stopped), not(s.committed), s' = { ...s, stopped: true, saved: s.baseline, savedTranscript: s.transcript } }
  action resume = all { s.stopped, s' = { ...s, stopped: false } }
  action freshReview = all { not(s.stopped), s.owner == "build", s.verified == s.candidate, s' = { ...s, owner: "review", baseline: -1, comparison: -1, transcript: 0, unsupported: false, fallbacks: 0 } }
  action edit = all { not(s.stopped), not(s.committed), s' = { ...s, candidate: s.candidate + 1, verified: -1, reviewed: -1 } }
  action verify = all { not(s.stopped), not(s.committed), s' = { ...s, verified: s.candidate } }
  action approve = all { s.owner == "review", not(s.stopped), s.verified == s.candidate, s' = { ...s, reviewed: s.candidate } }
  action commit = all { not(s.stopped), s.owner == "review", s.verified == s.candidate, s.reviewed == s.candidate, s' = { ...s, committed: true } }
  action idle = s' = s
  action step = any { complete, duplicate, failure, rejectOption, stop, resume, freshReview, edit, verify, approve, commit, idle }
  val CountOnce = s.input == s.seen.size() * 10 and s.cached == s.seen.size() * 2 and s.cached <= s.input and s.unknown >= 0
  val Continuity = s.stopped implies (s.baseline == s.saved and s.transcript == s.savedTranscript)
  val ScopedComparison = s.comparison == -1 or (s.comparison < s.baseline and s.seen.contains(s.comparison))
  val BoundedCompatibility = s.fallbacks <= 1
  val CacheIsNotAuthority = s.committed implies (s.owner == "review" and s.verified == s.candidate and s.reviewed == s.candidate)
}
