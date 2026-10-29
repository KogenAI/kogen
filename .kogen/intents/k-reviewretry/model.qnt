module retry {
 var n: int
 var used: bool
 var rejected: int
 var prose: int
 var phase: str
 var same: bool
 action init = all { n' = 1, used' = false, rejected' = 0, prose' = 0, phase' = "review", same' = true }
 action reject = all { phase == "review", rejected == 0, rejected' = 1, prose' = prose, n' = n, used' = used, phase' = phase, same' = same }
 action noTool = all { phase == "review", prose == 0, prose' = 1, rejected' = rejected, n' = n, used' = used, phase' = phase, same' = same }
 action invalid = all { phase == "review", any { rejected == 1, prose == 1 }, phase' = if (not(used) and same) "review" else "stopped", n' = if (not(used) and same) n + 1 else n, used' = true, rejected' = 0, prose' = 0, same' = same }
 action drift = all { phase == "stopped", same' = false, n' = n, used' = used, rejected' = rejected, prose' = prose, phase' = phase }
 action resume = all { phase == "stopped", same, phase' = "review", n' = n + 1, used' = used, rejected' = 0, prose' = 0, same' = same }
 action approve = all { phase == "review", same, phase' = "landed", n' = n, used' = used, rejected' = rejected, prose' = prose, same' = same }
 action idle = all { n' = n, used' = used, rejected' = rejected, prose' = prose, phase' = phase, same' = same }
 action step = any { reject, noTool, invalid, drift, resume, approve, idle }
 val Safe = all { rejected <= 1, prose <= 1, n >= 1, phase == "landed" implies same, n > 1 implies used }
}
