module claude_roles {
  var selected: int
  var credential: bool
  var approved: bool
  var verified: bool
  var reviewed: bool
  var blocked: bool
  var landed: bool
  var route: int

  action init = all {
    selected' = 0, credential' = false, approved' = false,
    verified' = false, reviewed' = false, blocked' = false,
    landed' = false, route' = 0
  }
  action choose = all {
    not(approved), not(landed),
    selected' = 1, route' = 1, credential' = false,
    approved' = approved, verified' = verified,
    reviewed' = reviewed, blocked' = blocked, landed' = landed
  }
  action login = all {
    credential' = true, selected' = selected, route' = route,
    approved' = approved, verified' = verified, reviewed' = reviewed,
    blocked' = blocked, landed' = landed
  }
  action approve = all {
    credential, approved' = true, selected' = selected, route' = route,
    credential' = credential, verified' = verified, reviewed' = reviewed,
    blocked' = blocked, landed' = landed
  }
  action verify = all {
    approved, not(blocked), verified' = true,
    selected' = selected, route' = route, credential' = credential,
    approved' = approved, reviewed' = reviewed, blocked' = blocked, landed' = landed
  }
  action review = all {
    verified, not(blocked), reviewed' = true,
    selected' = selected, route' = route, credential' = credential,
    approved' = approved, verified' = verified, blocked' = blocked, landed' = landed
  }
  action stop = all {
    verified, not(landed), blocked' = true, reviewed' = false,
    selected' = selected, route' = route, credential' = credential,
    approved' = approved, verified' = verified, landed' = landed
  }
  action resume = all {
    blocked, blocked' = false, verified' = false, reviewed' = false,
    selected' = selected, route' = route, credential' = credential,
    approved' = approved, landed' = landed
  }
  action land = all {
    approved, credential, verified, reviewed, not(blocked),
    landed' = true, selected' = selected, route' = route,
    credential' = credential, approved' = approved, verified' = verified,
    reviewed' = reviewed, blocked' = blocked
  }
  action step = any { choose, login, approve, verify, review, stop, resume, land }
  val NoFallback = route == selected
  val SafeLanding = landed implies (approved and credential and verified and reviewed and not(blocked))
}
