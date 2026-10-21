module terminal_validation_evidence {
  var s: { invalidSeen: bool, pending: bool, itemsValid: bool, terminal: bool, accepted: bool, evidence: bool, usageKnown: bool }
  action init = s' = { invalidSeen: false, pending: false, itemsValid: false, terminal: false, accepted: false, evidence: false, usageKnown: false }
  action added = all { not(s.terminal), s' = { ...s, pending: true } }
  action invalidEvent = all { not(s.terminal), s' = { ...s, invalidSeen: true } }
  action itemDone = all { not(s.terminal), s' = { ...s, pending: false, itemsValid: true } }
  action complete = {
    nondet replacement = Set(true, false).oneOf()
    nondet validFinal = Set(true, false).oneOf()
    nondet envelopeValid = Set(true, false).oneOf()
    nondet hasUsage = Set(true, false).oneOf()
    val itemsOk = if (replacement) validFinal else s.itemsValid
    val pending = if (replacement) false else s.pending
    val invalid = s.invalidSeen or not(envelopeValid)
    val ok = not(invalid) and itemsOk and not(pending)
    all { not(s.terminal), s' = { invalidSeen: invalid, pending: pending, itemsValid: itemsOk, terminal: true, accepted: ok, evidence: not(ok), usageKnown: ok and hasUsage } }
  }
  action idle = s' = s
  action step = any { added, invalidEvent, itemDone, complete, idle }
  val ValidationUnchanged = s.terminal implies (s.accepted == (not(s.invalidSeen) and s.itemsValid and not(s.pending)))
  val HonestEvidence = (s.terminal implies (s.evidence == not(s.accepted))) and (s.usageKnown implies s.accepted)
}
