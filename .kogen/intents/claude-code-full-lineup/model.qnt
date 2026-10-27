// Role ownership and Kogen gates, not a model of Claude inference or auth availability.
// Two parts and a two-round cap stand for arbitrary finite material and configured caps.
module claude_code_full_lineup {
  var s: { phase: str, tree: int, green: int, reviewed: int, commits: int, published: bool, cleanShape: bool, intact: bool, shapeSession: int, buildSession: int, reviewSession: int, parts: int, rounds: int, fallback: bool, reason: str }

  action init = {
    s' = { phase: "shape", tree: 0, green: -1, reviewed: -1, commits: 0, published: false, cleanShape: true, intact: true, shapeSession: 1, buildSession: 2, reviewSession: 0, parts: 0, rounds: 0, fallback: false, reason: "" }
  }

  action stop(reason: str): bool = { s' = s.with("phase", "stopped").with("reason", reason) }

  action shapeRound = all {
    s.phase == "shape", s.rounds < 2,
    nondet outcome = Set("files", "feedback", "mutation", "protocol", "auth").oneOf()
    if (outcome == "mutation") {
      s' = s.with("phase", "stopped").with("cleanShape", false).with("reason", "checkout_changed")
    } else if (outcome == "protocol" or outcome == "auth") stop(outcome)
    else if (outcome == "files") {
      s' = s.with("published", true).with("phase", "build").with("rounds", 0)
    } else { s' = s.with("rounds", s.rounds + 1) },
  }

  action buildRound = all {
    s.phase == "build", s.rounds < 2,
    s' = s.with("tree", s.tree + 1).with("phase", "verify").with("rounds", s.rounds + 1),
  }

  action verify = all {
    s.phase == "verify",
    nondet green = Set(true, false).oneOf()
    if (green) {
      s' = s.with("green", s.tree).with("phase", "review").with("reviewSession", 3).with("rounds", 0)
    } else { s' = s.with("phase", "build") },
  }

  // Only completed Kogen-observed delivery of each exact part earns this count.
  action deliverPart = all {
    s.phase == "review", s.parts < 2,
    s' = s.with("parts", s.parts + 1),
  }

  action reviewRound = all {
    s.phase == "review", s.rounds < 2,
    nondet outcome = Set("approve", "repair", "changes", "protocol", "auth").oneOf()
    if (outcome == "approve" and s.parts != 2) stop("delivery_incomplete")
    else if (outcome == "approve") {
      s' = s.with("reviewed", s.tree).with("phase", "review_verify").with("rounds", s.rounds + 1)
    } else if (outcome == "repair") {
      s' = s.with("tree", s.tree + 1).with("rounds", s.rounds + 1)
    } else stop(outcome),
  }

  // Red stays with reviewer 3; it cannot start the builder again.
  action verifyReview = all {
    s.phase == "review_verify",
    nondet green = Set(true, false).oneOf()
    if (green) { s' = s.with("green", s.tree).with("phase", "commit") }
    else { s' = s.with("reviewed", -1).with("phase", "review") },
  }

  action limit = all {
    Set("shape", "build", "review").contains(s.phase), s.rounds == 2,
    stop("executor_round_limit"),
  }

  action protectedMutation = all {
    Set("build", "verify", "review", "review_verify", "commit").contains(s.phase),
    s' = s.with("intact", false).with("phase", "stopped").with("reason", "baseline_changed"),
  }

  action commit = all {
    s.phase == "commit", s.intact, s.tree == s.green, s.tree == s.reviewed, s.parts == 2,
    s' = s.with("commits", 1).with("phase", "landed"),
  }

  // External checkpoints have no exact resume. Explicit refusal is a stutter, not a retry.
  action terminal = all { Set("stopped", "landed").contains(s.phase), s' = s }
  action step = any { shapeRound, buildRound, verify, deliverPart, reviewRound, verifyReview, limit, protectedMutation, commit, terminal }

  val ExactDelivery = s.reviewed < 0 or s.parts == 2
  val IndependentSessions = s.shapeSession != s.buildSession and (s.reviewSession == 0 or (s.reviewSession != s.buildSession and s.reviewSession != s.shapeSession))
  val SingleExactCommit = s.commits >= 0 and s.commits <= 1 and (s.commits == 0 or (s.phase == "landed" and s.intact and s.tree == s.green and s.tree == s.reviewed and s.parts == 2))
  val SafePublication = not(s.published) or s.cleanShape
  val NoFallback = not(s.fallback)
}
