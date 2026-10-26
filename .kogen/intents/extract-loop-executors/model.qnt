module model {
  type State = { phase: str, backend: str, tree: int, green: int, reviewed: int,
    rounds: int, intact: bool, approved: bool, commits: int, runs: int,
    effects: int, refused: bool }
  var s: State

  action init = {
    nondet backend = Set("native", "claude-code").oneOf()
    s' = { phase: "approval", backend: backend, tree: 0, green: -1, reviewed: -1,
      rounds: 0, intact: true, approved: false, commits: 0, runs: 0,
      effects: 0, refused: false }
  }

  action approve = all {
    s.phase == "approval",
    s' = { ...s, phase: "build", approved: true, runs: 1 },
  }

  // A round produces a claim, never verification/review/commit authority.
  // The finite cap 2 represents a configured external cap; native is unbounded.
  action round = all {
    s.phase == "build",
    nondet outcome = Set("finish", "no_call", "protected", "head", "protocol").oneOf()
    s' = { ...s, rounds: s.rounds + 1, effects: s.effects + 1,
      tree: s.tree + 1, green: -1, reviewed: -1,
      intact: s.intact and not(Set("protected", "head").contains(outcome)),
      phase: if (Set("finish", "no_call").contains(outcome)) "verify" else "stopped" },
  }

  // Kogen owns fixers and actual verification after each safe round.
  action verify = all {
    s.phase == "verify",
    nondet pass = Set(true, false).oneOf()
    s' = if (pass) { ...s, green: s.tree, phase: "review" }
      else { ...s, phase: if (s.backend == "claude-code" and s.rounds >= 2) "stopped" else "build" },
  }

  action review = all {
    s.phase == "review",
    nondet decision = Set("approve", "repair", "block").oneOf()
    s' = if (decision == "approve") { ...s, reviewed: s.tree, phase: "commit" }
      else if (decision == "repair") { ...s, tree: s.tree + 1, green: -1, reviewed: -1, phase: "verify" }
      else { ...s, phase: "stopped" },
  }

  action commit = all {
    s.phase == "commit", s.approved, s.intact,
    s.green == s.tree, s.reviewed == s.tree,
    s' = { ...s, phase: "done", commits: 1 },
  }

  // Late tree drift cannot reuse a review or verification of older bytes.
  action drift = all {
    Set("review", "commit").contains(s.phase),
    s' = { ...s, tree: s.tree + 1, green: -1, reviewed: -1, phase: "verify" },
  }

  // External resume is refused before creating any new run or effect.
  action refuseResume = all {
    s.backend == "claude-code", s.phase == "stopped",
    s' = { ...s, refused: true },
  }

  action step = any { approve, round, verify, review, commit, drift, refuseResume, s' = s }

  val CheckedCommit = s.commits == 0 or
    (s.approved and s.intact and s.green == s.tree and s.reviewed == s.tree and s.phase == "done")
  val BoundedExternal = s.backend != "claude-code" or s.rounds <= 2
  val RefusalWithoutEffects = not(s.refused) or
    (s.phase == "stopped" and s.runs == 1 and s.effects == s.rounds and s.commits == 0)
}
