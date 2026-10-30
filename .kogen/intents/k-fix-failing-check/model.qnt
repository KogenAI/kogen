module baseline {
  var phase: int
  var green: bool
  var reviewed: bool
  action init = all { phase' = 0, green' = false, reviewed' = false }
  action step = any {
    all { phase == 0, phase' = 1, green' = green, reviewed' = reviewed },
    all { phase == 1, phase' = 1, green' = nondet g = oneOf(Set(false, true)); g, reviewed' = false },
    all { phase == 1, green, phase' = 2, green' = green, reviewed' = true },
    all { phase == 2, phase' = 3, green' = green, reviewed' = reviewed },
    all { phase == 3, phase' = phase, green' = green, reviewed' = reviewed }
  }
  val SafeLanding = phase != 3 or (green and reviewed)
}
