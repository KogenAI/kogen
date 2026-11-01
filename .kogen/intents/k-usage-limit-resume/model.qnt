module usage {
  var completed: int
  var saved: int
  var phase: str
  var round: int
  action init = all { completed' = 0, saved' = 0, phase' = "running", round' = 1 }
  action finish = all { phase == "running", completed < 3, completed' = completed + 1, saved' = saved, phase' = phase, round' = round + 1 }
  action limit = all { phase == "running", phase' = "limited", saved' = completed, completed' = completed, round' = round }
  action resume = all { phase == "limited", phase' = "running", completed' = completed, saved' = saved, round' = round }
  action otherError = all { phase == "running", phase' = "failed", completed' = completed, saved' = saved, round' = round }
  action stay = all { completed' = completed, saved' = saved, phase' = phase, round' = round }
  action step = any { finish, limit, resume, otherError, stay }
  val Preserved = completed >= saved and round == completed + 1
}
