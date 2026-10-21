module checkout_cli_dx {
  type Checkout = { last: int, rid: int, parent: int, root: int, phase: str, pass: int, alive: bool, valid: bool }
  pure val empty: Checkout = { last: -1, rid: -1, parent: -1, root: -1, phase: "idle", pass: 0, alive: false, valid: true }
  var a: Checkout
  var b: Checkout
  var priorOther: Checkout
  var selected: int
  var serial: int
  action init = all { a' = empty, b' = empty, priorOther' = empty, selected' = 0, serial' = 0 }
  pure def active(c: Checkout): bool = c.valid and c.alive and Set("startup", "building", "verifying", "reviewing", "committing").contains(c.phase)
  action step = {
    nondet which = Set(0, 1).oneOf()
    nondet op = Set("start", "resume", "verify", "build", "review", "commit", "stop", "crash", "invalid", "read", "reject").oneOf()
    val c = if (which == 0) a else b
    val starts = (op == "start" and not(active(c))) or (op == "resume" and c.valid and not(c.alive) and c.rid >= 0 and c.phase != "landed")
    val updated = if (starts) { last: serial, rid: serial, parent: if (op == "resume") c.rid else -1, root: if (op == "resume") c.root else serial, phase: "startup", pass: if (op == "resume") c.pass else 0, alive: true, valid: true }
      else if (op == "crash") { ...c, alive: false }
      else if (op == "invalid") { ...c, valid: false }
      else if (active(c) and op == "verify") { ...c, phase: "verifying", pass: c.pass + 1 }
      else if (active(c) and op == "build") { ...c, phase: "building" }
      else if (active(c) and op == "review") { ...c, phase: "reviewing" }
      else if (active(c) and op == "commit") { ...c, phase: "committing" }
      else if (active(c) and op == "stop") { ...c, phase: if (c.phase == "committing") "landed" else "stopped", alive: false }
      else c
    all { a' = if (which == 0) updated else a, b' = if (which == 1) updated else b,
      priorOther' = if (which == 0) b else a, selected' = which, serial' = if (starts) serial + 1 else serial }
  }
  pure def honest(c: Checkout): bool = (active(c) implies (c.rid == c.last and c.rid >= 0 and c.root <= c.rid and c.valid and c.alive)) and (c.phase == "verifying" implies c.pass > 0) and (c.parent >= 0 implies (c.parent < c.rid and c.root <= c.parent))
  val Facts = honest(a) and honest(b)
  val Isolation = if (selected == 0) b == priorOther else a == priorOther
  val Safety = Facts and Isolation
}
