module coverage {
  var s: { rows: Set[int], root: bool, child: bool, filtered: bool, whole: bool, reported: bool, input: int, summary: int, missing: int }
  action init = s' = { rows: Set(), root: false, child: false, filtered: false, whole: true, reported: false, input: 0, summary: -1, missing: -1 }
  action observe = {
    nondet row = Set(0, 1, 2).oneOf()
    s' = { ...s, rows: s.rows.union(Set(row)), reported: false }
  }
  action summary = {
    nondet child = Set(true, false).oneOf()
    s' = { ...s, root: s.root or not(child), child: s.child or child, reported: false }
  }
  action scope = {
    nondet filtered = Set(true, false).oneOf()
    nondet whole = Set(true, false).oneOf()
    s' = { ...s, filtered: filtered, whole: whole, reported: false }
  }
  val eligible = s.whole and not(s.filtered) and (s.root or s.child)
  val completed = s.rows.intersect(Set(1, 2)).size()
  val unresolved = if (s.rows.contains(0) and not(s.rows.contains(1))) 1 else 0
  action report = s' = { ...s, reported: true, input: completed * 10, summary: if (eligible) 1 else -1, missing: if (eligible) 1 - unresolved else -1 }
  action idle = s' = s
  action step = any { observe, summary, scope, report, idle }
  val TokensStayRetained = s.reported implies s.input == completed * 10
  val NoSummaryDoubleCount = s.reported implies s.summary <= 1
  val HonestAllocation = s.reported implies (if (eligible) s.missing == 1 - unresolved else (s.summary == -1 and s.missing == -1))
}
