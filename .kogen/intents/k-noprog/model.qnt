module noprog {
 var on: bool
 var streak: int
 var stopped: bool
 action init = all { on' = false, streak' = 0, stopped' = false }
 action step = if (stopped) { all { on' = on, streak' = streak, stopped' = stopped } } else { nondet opt = Set(true, false).oneOf(); nondet same = Set(true, false).oneOf(); val n = if (opt) { if (same) { streak + 1 } else { 1 } } else { 0 }; all { on' = opt, streak' = n, stopped' = (opt and n >= 3) } }
 val Safe = (streak >= 0 and streak <= 3) and (stopped implies (on and streak == 3))
}
