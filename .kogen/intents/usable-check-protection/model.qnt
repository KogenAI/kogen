module protection_model {
  var phase: str
  var conflict: bool
  var approved: bool
  var protectedChanged: bool
  action init = all { phase' = "new", conflict' = false, approved' = false, protectedChanged' = false }
  action configure = all { phase == "new", phase' = "configured", conflict' = false, approved' = false, protectedChanged' = false }
  action shape = {
    nondet blocked = Set(true, false).oneOf()
    all { phase == "configured", phase' = if (blocked) "blocked" else "ready", conflict' = blocked, approved' = false, protectedChanged' = false }
  }
  action approve = all { phase == "ready", not(conflict), phase' = "approved", conflict' = conflict, approved' = true, protectedChanged' = false }
  action build = {
    nondet touchesProtected = Set(true, false).oneOf()
    all { phase == "approved", approved, phase' = if (touchesProtected) "stopped" else "landed", protectedChanged' = touchesProtected, conflict' = conflict, approved' = approved }
  }
  action stutter = all { phase' = phase, conflict' = conflict, approved' = approved, protectedChanged' = protectedChanged }
  action step = any { configure, shape, approve, build, stutter }
  val ConflictIsNotReady = conflict implies (phase == "blocked" and not(approved))
  val ProtectedChangeNeverLands = protectedChanged implies phase == "stopped"
  val LandedWasApproved = phase == "landed" implies approved
}
