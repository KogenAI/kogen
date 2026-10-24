module approval_card_recovery {
  var current: int
  var approved: int
  var history: Set[int]
  var issued: Set[int]
  var built: int

  action init = all {
    current' = 1, approved' = 1, history' = Set(), issued' = Set(1), built' = 0
  }
  action replace = all {
    current' = current + 1, approved' = approved, history' = history,
    issued' = issued, built' = 0
  }
  action card = all {
    current' = current, approved' = approved, history' = history,
    issued' = issued, built' = built
  }
  action approve = all {
    current' = current, approved' = current,
    history' = if (approved > 0 and approved != current) history.union(Set(approved)) else history,
    issued' = issued.union(Set(current)), built' = built
  }
  action refine = all {
    current' = current + 1, approved' = 0,
    history' = if (approved > 0) history.union(Set(approved)) else history,
    issued' = issued, built' = 0
  }
  action build = all {
    approved == current, current' = current, approved' = approved,
    history' = history, issued' = issued, built' = current
  }
  action step = any { replace, card, approve, refine, build }
  val ExactAuthority = built == 0 or built == current
  val RetainedHistory = issued.subseteq(history.union(if (approved > 0) Set(approved) else Set()))
}
