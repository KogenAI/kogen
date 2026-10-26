module anthropic_complete_tool_turn {
  var complete: bool
  var valid: bool
  var calls: int
  var text: bool
  var reason: str
  var exposed: int
  var marker: bool
  action init = all {
    complete' = false, valid' = true, calls' = 0,
    text' = false, reason' = "", exposed' = 0, marker' = false,
  }
  action step = {
    nondet c = Set(false, true).oneOf()
    nondet v = Set(false, true).oneOf()
    nondet n = Set(0, 1, 2).oneOf()
    nondet t = Set(false, true).oneOf()
    nondet r = Set("end_turn", "tool_use", "max_tokens", "refusal", "pause_turn", "stop_sequence", "model_context_window_exceeded").oneOf()
    val answer = c and v and ((r == "end_turn" and (t or n > 0)) or (r == "tool_use" and n > 0))
    all {
      complete' = c, valid' = v, calls' = n, text' = t, reason' = r,
      exposed' = if (answer) n else 0,
      marker' = (answer and r == "end_turn" and n > 0),
    }
  }
  val NoPartialCalls = exposed == 0 or (complete and valid and exposed == calls and Set("end_turn", "tool_use").contains(reason))
  val ExactMarker = marker == (complete and valid and reason == "end_turn" and calls > 0)
}
