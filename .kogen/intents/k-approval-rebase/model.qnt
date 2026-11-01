module approval_rebase {
  var base: int
  var approved: int
  var built: bool
  action init = all { base' = 0, approved' = 0, built' = false }
  action move = all { base' = base + 1, approved' = approved, built' = false }
  action approve = all { approved' = base, base' = base, built' = false }
  action build = all { approved == base, built' = true, base' = base, approved' = approved }
  action step = any { move, approve, build }
  val AuthorizedBase = built implies approved == base
}
