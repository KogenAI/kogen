module counter {
  var count: int
  action init = all { count' = 0 }
  action step = any { init, all { count' = count + 1 } }
  val NeverNegative = count >= 0
}
