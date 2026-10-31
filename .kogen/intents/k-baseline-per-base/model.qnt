module baseline_model {
  var tree: int
  var saved: int
  var eligible: bool
  var reused: bool
  action init = all { tree' = 0, saved' = -1, eligible' = true, reused' = false }
  action step = any {
    all { tree' = 1 - tree, saved' = saved, eligible' = eligible, reused' = false },
    all { tree' = tree, saved' = saved, eligible' = not(eligible), reused' = false },
    all { tree' = tree, saved' = tree, eligible' = eligible, reused' = (eligible and saved == tree) }
  }
  val SafeReuse = reused implies (eligible and saved == tree)
}
