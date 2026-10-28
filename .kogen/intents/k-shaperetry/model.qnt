module retry {
  var invalid: int
  var limit: int
  var done: bool
  action init = all { invalid' = 0, limit' = 3, done' = false }
  action step = if (done) all { invalid' = invalid, limit' = limit, done' = done } else any {
    all { invalid' = invalid + 1, limit' = limit, done' = invalid + 1 >= limit },
    all { invalid' = invalid, limit' = limit, done' = true }
  }
  val Bounded = invalid <= limit
}
