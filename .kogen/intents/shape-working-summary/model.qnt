module model_summary {
  var docs: List[int]
  var snapshots: List[List[int]]
  var chain: List[int]
  var safe: bool
  var sent: bool
  var stopped: bool
  var bytes: int
  var authority: int

  action init = all {
    docs' = List(), snapshots' = List(), chain' = List(), safe' = true,
    sent' = false, stopped' = false, bytes' = 0, authority' = 0,
  }
  action lookup = all {
    not(stopped), docs.length() < 4,
    nondet d = Set(0, 1).oneOf()
    docs' = docs.append(d), snapshots' = snapshots, chain' = chain,
    safe' = safe, sent' = false, stopped' = false, bytes' = bytes, authority' = authority,
  }
  action reset = all {
    not(stopped), chain.length() < 4,
    nondet nextBytes = Set(524287, 524288, 524289).oneOf()
    all {
      docs' = docs, authority' = authority, safe' = safe,
      snapshots' = if (safe) snapshots.append(docs) else snapshots,
      chain' = if (safe) chain.append(chain.length() + 1) else chain,
      bytes' = nextBytes, sent' = (safe and nextBytes <= 524288),
      stopped' = (not(safe) or nextBytes > 524288),
    },
  }
  action corrupt = all {
    not(stopped), chain.length() > 0,
    docs' = docs, snapshots' = snapshots, chain' = chain, safe' = false,
    sent' = false, stopped' = stopped, bytes' = bytes, authority' = authority,
  }
  action stay = all {
    docs' = docs, snapshots' = snapshots, chain' = chain, safe' = safe,
    sent' = sent, stopped' = stopped, bytes' = bytes, authority' = authority,
  }
  action step = any { lookup, reset, corrupt, stay }
  val Safety = all {
    authority == 0,
    snapshots.length() == chain.length(),
    chain.indices().forall(i => chain.nth(i) == i + 1),
    sent implies (safe and not(stopped) and bytes <= 524288 and chain.length() > 0),
    if (sent) snapshots.nth(snapshots.length() - 1) == docs else true,
  }
}
