module transient_stream_retry {
  // Seconds abstract the fixed 1800-second monotonic budget. No refresh/cache retry is added.
  var s: { phase: str, attempts: int, elapsed: int, tools: int, complete: bool, single: bool }
  action init = {
    nondet single = Set(true, false).oneOf()
    s' = {phase: "request", attempts: 1, elapsed: 0, tools: 0, complete: false, single: single}
  }
  action transient = all {
    s.phase == "request",
    s' = {...s, phase: if (s.single or s.attempts == 3) "stopped" else "backoff"}
  }
  action retry = all {
    s.phase == "backoff",
    val delay = if (s.attempts == 1) 2 else 8
    s' = if (s.elapsed + delay >= 1800) {...s, elapsed: 1800, phase: "stopped"}
         else {...s, elapsed: s.elapsed + delay, attempts: s.attempts + 1, phase: "request"}
  }
  action wait = all {
    Set("request", "backoff").contains(s.phase),
    nondet delta = Set(1, 2, 8, 1799, 1800).oneOf()
    val elapsed = if (s.elapsed + delta >= 1800) 1800 else s.elapsed + delta
    s' = {...s, elapsed: elapsed, phase: if (elapsed == 1800) "stopped" else s.phase}
  }
  action refusalOrCancel = all {
    Set("request", "backoff").contains(s.phase), s' = {...s, phase: "stopped"}
  }
  action complete = all {
    s.phase == "request", s.elapsed < 1800,
    s' = {...s, phase: "completed", complete: true}
  }
  action tool = all { s.phase == "completed", s' = {...s, phase: "done", tools: 1} }
  action idle = all { Set("done", "stopped").contains(s.phase), s' = s }
  action step = any {transient, retry, wait, refusalOrCancel, complete, tool, idle}
  val Bounds = s.attempts >= 1 and s.attempts <= 3 and s.elapsed <= 1800 and (s.single implies s.attempts == 1)
  val NoPartialTools = s.tools <= 1 and (s.tools > 0 implies s.complete)
  val StopIsFinal = s.phase == "stopped" implies (not(s.complete) and s.tools == 0)
}
