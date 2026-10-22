module shaping_technical_discovery {
  type S = { inspected: bool, probes: int, cited: int, asked: bool, kind: str, blocked: bool, published: bool, rejected: int, external: bool, searched: bool, fetched: bool, adopted: bool }
  var s: S
  action init = s' = { inspected: false, probes: 0, cited: 0, asked: false, kind: "none", blocked: false, published: false, rejected: 0, external: false, searched: false, fetched: false, adopted: false }
  action read = all { not(s.published), s' = { ...s, inspected: true } }
  action probe = all { not(s.published), s.probes < 2, s' = { ...s, probes: s.probes + 1 } }
  action cite = all { not(s.published), s.cited < s.probes, s' = { ...s, cited: s.cited + 1 } }
  action depend = all { not(s.published), s' = { ...s, external: true } }
  action searchDocs = all { not(s.published), s' = { ...s, searched: true } }
  action fetchDocs = all { not(s.published), s.searched, s' = { ...s, fetched: true } }
  action adoptUntrusted = all { not(s.published), s' = { ...s, adopted: true } }
  action askProduct = all { not(s.published), not(s.blocked), s' = { ...s, asked: true, kind: "product" } }
  action askHandoff = all { not(s.published), not(s.blocked), s' = { ...s, asked: true, kind: "handoff" } }
  action askEngineering = all { not(s.published), s.rejected < 2, s' = { ...s, asked: false, rejected: s.rejected + 1 } }
  action answer = all { s.asked, not(s.published), s' = { ...s, asked: false, kind: "none" } }
  action block = all { not(s.published), not(s.asked), s' = { ...s, blocked: true } }
  action publish = all {
    not(s.published),
    s.inspected,
    s.cited == s.probes,
    not(s.asked),
    not(s.blocked),
    not(s.adopted),
    not(s.external) or (s.searched and s.fetched),
    s' = { ...s, published: true, kind: "none" }
  }
  action idle = s' = s
  action step = any {
    read, probe, cite, depend, searchDocs, fetchDocs, adoptUntrusted,
    askProduct, askHandoff, askEngineering, answer, block, publish, idle
  }
  val PublishedMeansInspected = s.published implies (s.inspected and s.cited == s.probes and not(s.asked) and not(s.blocked))
  val NoEngineeringDelivery = s.asked implies (s.kind == "product" or s.kind == "handoff")
  val ExternalNeedsDiscovery = s.published implies (not(s.external) or (s.searched and s.fetched and not(s.adopted)))
}
