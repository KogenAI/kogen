// K-REVIEW-SOURCE-BOUND: an external (Claude Code) reviewer's complete first prompt is measured,
// source included, against the unchanged inclusive 524288-byte ceiling before it is sent. A
// fitting prompt is the unchanged single inline review. Otherwise the exact source is cut in
// order into parts, each reviewed by its own fresh session whose complete prompt fits: the
// candidate lands only when every part approved and every source byte was sent, a blocking part
// stops the later parts, mandatory material that leaves fewer than 6000 bytes for source stops
// before anything is sent, and a provider refusal is a context result, never an ordinary
// executor failure.
module reviewSourceBound {
  // "reviewing", "landed", "blocked", "too_large" (stopped before sending),
  // "refused" (Claude Code refused a sent prompt as too long)
  var stage: str
  // the class/reason the Build stops with ("" while reviewing or landed)
  var result: str
  // 0: one inline review; otherwise the number of parts
  var parts: int
  // the part under review (1-based)
  var current: int
  var approved: int
  // review sessions started, each with one first prompt
  var sessions: int
  // bytes of the newest first prompt sent (0: none sent)
  var promptBytes: int
  // the prompt bytes that are not source, and the source bytes not yet sent
  var mandatory: int
  var remaining: int
  var committed: bool

  pure val Ceiling = 524288
  pure val MinimumRoom = 6000

  pure def needed(p: int): int = if (p == 0) 1 else p
  pure def min2(a: int, b: int): int = if (a < b) a else b

  action keep(st: str, rs: str, p: int, c: int, a: int, s: int, pb: int, m: int, r: int, cm: bool): bool = all {
    stage' = st, result' = rs, parts' = p, current' = c, approved' = a, sessions' = s,
    promptBytes' = pb, mandatory' = m, remaining' = r, committed' = cm,
  }

  // Measuring before anything is sent, then the first session.
  action init = {
    nondet m = Set(20000, 300000, 519000, 600000).oneOf()
    nondet whole = Set(0, 100000, 500000, 2900000).oneOf()
    val room = Ceiling - m
    if (m + whole <= Ceiling)
      // unchanged: one inline review carrying the complete source
      keep("reviewing", "", 0, 1, 0, 1, m + whole, m, 0, false)
    else if (room < MinimumRoom)
      keep("too_large", "candidate/context_budget_exceeded", 0, 0, 0, 0, 0, m, whole, false)
    else
      keep("reviewing", "", (whole + room - 1) / room, 1, 0, 1, m + min2(room, whole), m, whole - min2(room, whole), false)
  }

  // The current part's session approves (its verified repairs included).
  action approve = all {
    stage == "reviewing",
    if (approved + 1 == needed(parts))
      keep("landed", "", parts, current, approved + 1, sessions, promptBytes, mandatory, remaining, true)
    else {
      // the next part: its own fresh session, its piece of the remaining source
      val piece = min2(Ceiling - mandatory, remaining)
      keep("reviewing", "", parts, current + 1, approved + 1, sessions + 1, mandatory + piece, mandatory, remaining - piece, false)
    },
  }

  action block = all {
    stage == "reviewing",
    keep("blocked", "candidate/review_blocked", parts, current, approved, sessions, promptBytes, mandatory, remaining, false),
  }

  // Claude Code answers a sent prompt with "Prompt is too long" (terminal reason blocking_limit).
  action refuse = all {
    stage == "reviewing",
    keep("refused", "candidate/context_budget_exceeded", parts, current, approved, sessions, promptBytes, mandatory, remaining, false),
  }

  action stopped = all {
    stage != "reviewing",
    keep(stage, result, parts, current, approved, sessions, promptBytes, mandatory, remaining, committed),
  }

  action step = any { approve, block, refuse, stopped }

  val NoPromptOverCeiling = promptBytes <= Ceiling
  val LandedOnlyWhenEveryPartApproved = committed implies (stage == "landed" and approved == needed(parts) and remaining == 0)
  val TooLargeSendsNothing = stage == "too_large" implies (sessions == 0 and promptBytes == 0 and not(committed))
  val BlockStopsLaterParts = stage == "blocked" implies (sessions == current and not(committed))
  val RefusalIsContextResult = stage == "refused" implies (result == "candidate/context_budget_exceeded" and not(committed))
  val OneSessionPerStartedPart = stage == "reviewing" implies sessions == current
}
