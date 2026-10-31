// Resume of a Build whose claude-code reviewer stopped after the candidate passed verification.
// Trees: 0 is the builder's green candidate (the review's base), 1 the stopped reviewer's
// uncommitted edits, 2 an edit of the fresh reviewer. A tree lands only when it is verified green
// and approved by a review session that judged exactly that tree; the stopped session never
// continues, and a blocking verdict is never cleared by a fresh session.
module model {
  var tree: int
  var green: Set[int]
  var session: str
  var approved: int
  var blocked: bool
  var stopped: bool
  var landed: int

  action init = all {
    nondet b = Set(true, false).oneOf()
    all {
      tree' = 1, green' = Set(0), session' = "old", approved' = -1,
      blocked' = b, stopped' = true, landed' = -1,
    }
  }

  // Explicit resume: a blocked review is refused unchanged; otherwise the stopped reviewer's
  // edits are discarded and one fresh session reviews the green base.
  action resume = all {
    stopped, landed == -1,
    if (blocked) all {
      tree' = tree, green' = green, session' = session, approved' = approved,
      blocked' = blocked, stopped' = stopped, landed' = landed,
    } else all {
      tree' = 0, green' = green, session' = "fresh", approved' = -1,
      blocked' = false, stopped' = false, landed' = -1,
    }
  }

  action approve = all {
    not(stopped), session == "fresh", landed == -1,
    approved' = tree,
    tree' = tree, green' = green, session' = session, blocked' = blocked, stopped' = stopped, landed' = landed,
  }

  // The fresh reviewer edits; external verification finds the edit green or not.
  action edit = all {
    not(stopped), session == "fresh", landed == -1,
    nondet ok = Set(true, false).oneOf()
    all {
      tree' = 2, approved' = -1,
      green' = if (ok) green.union(Set(2)) else green.exclude(Set(2)),
      session' = session, blocked' = blocked, stopped' = stopped, landed' = landed,
    }
  }

  action block = all {
    not(stopped), session == "fresh", landed == -1,
    blocked' = true, stopped' = true,
    tree' = tree, green' = green, session' = session, approved' = approved, landed' = landed,
  }

  action commit = all {
    not(stopped), landed == -1, approved == tree, green.contains(tree),
    landed' = tree, stopped' = true,
    tree' = tree, green' = green, session' = session, approved' = approved, blocked' = blocked,
  }

  action idle = all {
    tree' = tree, green' = green, session' = session, approved' = approved,
    blocked' = blocked, stopped' = stopped, landed' = landed,
  }

  action step = any { resume, approve, edit, block, commit, idle }

  val LandedReviewed = landed != -1 implies (green.contains(landed) and approved == landed and session == "fresh")
  val LandedNotBlocked = landed != -1 implies not(blocked)
  val NoStaleEdits = landed != 1
}
