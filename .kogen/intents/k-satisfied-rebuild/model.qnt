module satisfied {
  var phase: str
  var empty: bool
  var approval: bool
  var commits: int
  action init = all { phase' = "building", empty' = true, approval' = true, commits' = 0 }
  action verify = all { phase == "building", phase' = "verified", empty' = empty, approval' = approval, commits' = commits }
  action review = all { phase == "verified", phase' = "reviewed", empty' = empty, approval' = approval, commits' = commits }
  action finish = all { phase == "reviewed", phase' = "satisfied", empty' = empty, approval' = false, commits' = commits }
  action step = any { verify, review, finish }
  val Safe = commits == 0 and (phase != "satisfied" or not(approval))
}
