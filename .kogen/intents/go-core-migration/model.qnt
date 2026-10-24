module go_core_migration {
  var completed: int
  var candidate: int
  var verified: int
  var reviewed: int
  var approved: bool
  var intact: bool
  var stopped: bool
  var commits: int

  action init = all {
    completed' = 0, candidate' = 0, verified' = -1, reviewed' = -1,
    approved' = true, intact' = true, stopped' = false, commits' = 0,
  }

  action edit = all {
    not(stopped), commits == 0,
    candidate' = candidate + 1, completed' = completed,
    verified' = verified, reviewed' = reviewed, approved' = approved,
    intact' = intact, stopped' = stopped, commits' = commits,
  }

  action milestone = all {
    not(stopped), approved, intact, completed < 4, commits == 0,
    completed' = completed + 1, candidate' = candidate,
    verified' = verified, reviewed' = reviewed, approved' = approved,
    intact' = intact, stopped' = stopped, commits' = commits,
  }

  action verify = all {
    not(stopped), completed == 4, commits == 0,
    verified' = candidate, candidate' = candidate, completed' = completed,
    reviewed' = reviewed, approved' = approved, intact' = intact,
    stopped' = stopped, commits' = commits,
  }

  action review = all {
    not(stopped), completed == 4, verified == candidate, commits == 0,
    reviewed' = candidate, candidate' = candidate, completed' = completed,
    verified' = verified, approved' = approved, intact' = intact,
    stopped' = stopped, commits' = commits,
  }

  action stop = all {
    commits == 0,
    stopped' = true, completed' = completed, candidate' = candidate,
    verified' = verified, reviewed' = reviewed, approved' = approved,
    intact' = intact, commits' = commits,
  }

  action resume = all {
    stopped, approved, intact, commits == 0,
    stopped' = false, completed' = completed, candidate' = candidate,
    verified' = verified, reviewed' = reviewed, approved' = approved,
    intact' = intact, commits' = commits,
  }

  action drift = all {
    commits == 0,
    intact' = false, stopped' = true, completed' = completed,
    candidate' = candidate, verified' = verified, reviewed' = reviewed,
    approved' = approved, commits' = commits,
  }

  action commit = all {
    not(stopped), approved, intact, completed == 4,
    verified == candidate, reviewed == candidate, commits == 0,
    commits' = 1, completed' = completed, candidate' = candidate,
    verified' = verified, reviewed' = reviewed, approved' = approved,
    intact' = intact, stopped' = stopped,
  }

  action step = any { edit, milestone, verify, review, stop, resume, drift, commit }
  val ExactCommit = commits == 0 or (commits == 1 and approved and intact and verified == candidate and reviewed == candidate)
  val ProgressIsNotDelivery = completed == 4 or commits == 0
  val ResumeAuthority = not(intact) implies (stopped and commits == 0)
}
