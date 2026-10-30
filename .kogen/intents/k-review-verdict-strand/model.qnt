module verdict_strand {
  var automatic: bool
  var stopped: bool
  var reviewed: bool
  action init = all { automatic' = false, stopped' = false, reviewed' = false }
  action step = any {
    all { not(stopped), not(reviewed), not(automatic), automatic' = true, stopped' = false, reviewed' = false },
    all { not(stopped), not(reviewed), automatic, automatic' = automatic, stopped' = true, reviewed' = false },
    all { stopped, automatic' = automatic, stopped' = false, reviewed' = false },
    all { not(stopped), automatic' = automatic, stopped' = false, reviewed' = true }
  }
  val SafeStop = stopped implies automatic
  val NoImplicitApproval = not(stopped and reviewed)
}
