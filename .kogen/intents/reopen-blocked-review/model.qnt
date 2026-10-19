module reopen_blocked_review {
  var s: { phase: str, candidate: int, tested: int, approved: int, epoch: int, evidenceEpoch: int, owner: str, finding: bool, commits: int, safe: bool, pending: bool }
  action init = s' = { phase: "blocked", candidate: 1, tested: 0, approved: 0, epoch: 0, evidenceEpoch: 0, owner: "saved-reviewer", finding: true, commits: 0, safe: true, pending: false }
  action resume = all { s.phase == "blocked", s.safe, not(s.pending), s' = { ...s, phase: "verify", epoch: s.epoch + 1, tested: -1, approved: -1 } }
  action verify = { nondet green = Set(true, false).oneOf()
    all { s.phase == "verify", s' = { ...s, phase: "review", tested: if (green) s.candidate else -1, evidenceEpoch: s.epoch } }
  }
  action keepBlock = all { s.phase == "review", s' = { ...s, phase: "blocked", approved: -1 } }
  action clear = all { s.phase == "review", s.tested == s.candidate, s.evidenceEpoch == s.epoch, s' = { ...s, phase: "commit", approved: s.candidate } }
  action edit = all { s.phase == "review", s' = { ...s, phase: "verify", candidate: s.candidate + 1, tested: -1, approved: -1 } }
  action interrupt = all { Set("verify", "review").contains(s.phase), s' = { ...s, phase: "interrupted" } }
  action continue = all { s.phase == "interrupted", s.safe, not(s.pending), s' = { ...s, phase: if (s.evidenceEpoch == s.epoch and s.tested == s.candidate) "review" else "verify" } }
  action drift = all { Set("blocked", "interrupted").contains(s.phase), s' = { ...s, safe: false } }
  action uncertain = all { s.phase == "interrupted", s' = { ...s, pending: true } }
  action commit = all { s.phase == "commit", s.safe, not(s.pending), s.commits == 0, s' = { ...s, phase: "landed", commits: 1 } }
  action idle = s' = s
  action step = any { resume, verify, keepBlock, clear, edit, interrupt, continue, drift, uncertain, commit, idle }
  val FreshExactCommit = s.commits == 1 implies (s.tested == s.candidate and s.approved == s.candidate and s.evidenceEpoch == s.epoch and s.epoch > 0 and s.safe and not(s.pending))
  val Custody = s.owner == "saved-reviewer" and s.finding and s.commits <= 1
  val Safety = FreshExactCommit and Custody
}
