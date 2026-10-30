module approval_timing {
  var completed: int
  var total: int
  var refused: bool
  var done: bool
  var cause: str
  val Safe = all {
    done implies (completed == 3 and not(refused)),
    refused implies (cause == "command_failed" or cause == "step_timeout"),
    (cause == "none") implies not(refused)
  }
  action init = all { completed' = 0, total' = 0, refused' = false, done' = false, cause' = "none" }
  action advance = all {
    completed < 3, not(refused), not(done),
    nondet elapsed = 1.to(119).oneOf()
    all { completed' = completed + 1, total' = total + elapsed, refused' = false, done' = (completed + 1 == 3), cause' = "none" }
  }
  action reject = all {
    not(done), not(refused),
    nondet why = Set("command_failed", "step_timeout").oneOf()
    all { completed' = completed, total' = total, refused' = true, done' = false, cause' = why }
  }
  action stay = all { any { done, refused }, completed' = completed, total' = total, refused' = refused, done' = done, cause' = cause }
  action step = any { advance, reject, stay }
}
