module all_provider_cache_reuse {
  var s: { owner: int, key: int, disabled: Set[int], sentKey: bool, attempts: int, recorded: int, replay: int, original: int, stopped: bool }
  action init = s' = { owner: 0, key: 0, disabled: Set(), sentKey: false, attempts: 0, recorded: 0, replay: 7, original: 7, stopped: false }
  action request = all { not(s.stopped), s.attempts == s.recorded, s' = { ...s, sentKey: not(s.disabled.contains(s.owner)), attempts: s.attempts + 1 } }
  action complete = all { s.attempts == s.recorded + 1, s' = { ...s, recorded: s.recorded + 1 } }
  action rejectNamed = all { s.attempts == s.recorded + 1, s.sentKey, s' = { ...s, recorded: s.recorded + 1, disabled: s.disabled.union(Set(s.owner)), sentKey: false } }
  action rejectOther = all { s.attempts == s.recorded + 1, s' = { ...s, recorded: s.recorded + 1, stopped: true } }
  action newOwner = all { s.attempts == s.recorded, s.owner < 3, s' = { ...s, owner: s.owner + 1, key: s.key + 1, sentKey: false, stopped: false } }
  action restore = all { s.attempts == s.recorded, s' = s }
  action step = any { request, complete, rejectNamed, rejectOther, newOwner, restore }
  val Custody = s.replay == s.original and s.key == s.owner
  val OnceOnly = s.recorded <= s.attempts and s.attempts <= s.recorded + 1
  val Sticky = s.disabled.contains(s.owner) implies not(s.sentKey)
}
