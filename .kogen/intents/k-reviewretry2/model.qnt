module model {
  var reviews: int
  var spent: bool
  var valid: bool
  var stopped: bool
  action init = all { reviews' = 1, spent' = false, valid' = false, stopped' = false }
  action step = any {
    all { not(valid), not(stopped), valid' = true, reviews' = reviews, spent' = spent, stopped' = false },
    all { not(valid), not(stopped), not(spent), reviews' = reviews + 1, spent' = true, valid' = false, stopped' = false },
    all { not(valid), not(stopped), spent, stopped' = true, reviews' = reviews, spent' = spent, valid' = false },
    all { any { valid, stopped }, reviews' = reviews, spent' = spent, valid' = valid, stopped' = stopped }
  }
  val Budget = reviews >= 1 and reviews <= 2
  val Spent = (reviews == 2) == spent
  val Stop = stopped implies (spent and not(valid))
}
