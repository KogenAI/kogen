module kshell_model {
  var opted: bool
  var active: bool
  var alive: bool
  var stopped: bool
  var feedback: str
  action state(o, a, g, s, f) = all { opted' = o, active' = a, alive' = g, stopped' = s, feedback' = f }
  action init = { nondet o = Set(false, true).oneOf(); state(o, false, false, false, "") }
  action start = all { not(active), not(stopped), state(opted, true, true, false, "") }
  action ordinary = all { active, not(stopped), state(opted, false, false, false, "ordinary") }
  action expire = all { active, opted, not(stopped), state(opted, false, false, false, "timeout") }
  action interrupt = all { not(stopped), state(opted, false, false, true, "") }
  action step = any { start, ordinary, expire, interrupt }
  val Safety = (feedback == "timeout" implies (opted and not(active) and not(alive) and not(stopped))) and (stopped implies (feedback == "" and not(alive)))
  run timeoutContinuesTest = state(true, true, true, false, "").then(expire).then(start).expect(active and not(stopped))
  run interruptIsNotFeedbackTest = state(true, true, true, false, "").then(interrupt).expect(stopped and feedback == "")
}
