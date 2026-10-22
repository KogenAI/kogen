// SuperGrok device login, private credential refresh and provider-bound requests.
// Server answers, verification-address scheme, interval and lifetime are nondeterministic
// inputs: Kogen reads them from the device response and never assumes fixed values.
// Login starts without credentials; acceptance also tests preservation of an earlier login.
module supergrok_subscription {
  var s: {
    phase: str, interval: int, clock: int, expires: int, polls: int, lastPoll: int, lastGap: int, gapNeeded: int,
    granted: bool, stored: bool, refresh: int, kept: int, access: int, accepted: int, revoked: bool,
    pending: bool, retries: int, outcome: str, provider: str, owner: str,
    builderHistory: Set[int], replay: Set[int], nextItem: int
  }

  action init = {
    nondet https = oneOf(Set(true, false))
    nondet interval = oneOf(Set(1, 2, 5))
    nondet expires = oneOf(Set(3, 6, 1800))
    s' = {
      phase: if (https) "polling" else "failed", interval: interval, clock: 0, expires: expires, polls: 0,
      lastPoll: 0, lastGap: 0, gapNeeded: 0, granted: false, stored: false, refresh: 0, kept: 0, access: 0,
      accepted: 0, revoked: false, pending: false, retries: 0, outcome: "none", provider: "supergrok",
      owner: "build", builderHistory: Set(), replay: Set(), nextItem: 0
    }
  }

  action tick = all { s.phase == "polling", s.clock < 40, s' = { ...s, clock: s.clock + 1 } }

  action poll = {
    nondet r = oneOf(Set("pending", "slow_down", "denied", "expired", "granted", "granted_without_api"))
    all {
      s.phase == "polling", s.clock - s.lastPoll >= s.interval, s.clock < s.expires,
      s' = { ...s, polls: s.polls + 1, lastGap: s.clock - s.lastPoll, gapNeeded: s.interval, lastPoll: s.clock,
        interval: if (r == "slow_down") s.interval + 5 else s.interval,
        phase: if (r == "granted") "stored" else if (r == "pending" or r == "slow_down") "polling" else "failed",
        granted: r == "granted", stored: r == "granted" }
    }
  }

  action deadline = all { s.phase == "polling", s.clock >= s.expires, s' = { ...s, phase: "failed" } }
  action cancel = all { s.phase == "polling", s' = { ...s, phase: "cancelled" } }

  action request = all { s.phase == "stored", not(s.pending), s' = { ...s, pending: true, retries: 0, outcome: "none" } }

  action answer = {
    nondet r = oneOf(Set("ok", "s401", "s402", "s403", "s429"))
    nondet rotate = oneOf(Set(true, false))
    val status = if (s.access != s.accepted) "s401" else r
    all {
      s.pending,
      s' = if (status == "ok") { ...s, pending: false, outcome: "completed",
               replay: s.replay.union(Set(s.nextItem)), nextItem: s.nextItem + 1,
               builderHistory: if (s.owner == "build") s.builderHistory.union(Set(s.nextItem)) else s.builderHistory }
           else if (status == "s401" and s.retries == 0)
             { ...s, retries: 1, refresh: if (rotate) s.refresh + 1 else s.refresh,
               kept: if (rotate) s.refresh + 1 else s.refresh,
               access: if (s.revoked) s.access else s.accepted }
           else if (status == "s401") { ...s, pending: false, outcome: "login_rejected" }
           else if (status == "s429") { ...s, pending: false, outcome: "unavailable" }
           else { ...s, pending: false, outcome: "refused" }
    }
  }

  action expire = all { s.phase == "stored", s' = { ...s, accepted: s.accepted + 1 } }
  action revoke = all { s.phase == "stored", s' = { ...s, revoked: true, accepted: s.accepted + 1 } }
  // The ownership transition discards builder conversation input, not protected authority.
  // Require actual builder history so a copied-history mutation is observable.
  action review = all { s.phase == "stored", not(s.pending), s.owner == "build", s.builderHistory.size() > 0,
    s' = { ...s, owner: "review", replay: Set() } }
  action idle = s' = s
  action step = any { tick, poll, deadline, cancel, request, answer, expire, revoke, review, idle }

  // A credential exists only after a grant that includes api:access.
  val GrantedStore = s.stored implies s.granted
  // Denial, expiry, missing access, non-HTTPS verification and cancellation keep nothing.
  val NoPartialStore = (s.phase == "failed" or s.phase == "cancelled") implies not(s.stored)
  // Polls honor the server interval, raised by every slow_down, and stop at the server lifetime.
  val Paced = s.polls > 0 implies (s.lastGap >= s.gapNeeded and s.lastPoll < s.expires)
  // A refresh that omits rotation keeps the saved refresh token.
  val KeptRefresh = s.refresh == s.kept
  // One refresh and one retry after 401; 402/403/429 never refresh or retry here.
  val OneRetry = s.retries <= 1
  // Requests never move to another provider, model, API key or paid route.
  val NoFallback = s.provider == "supergrok"
  // The reviewer has its own growing replay, disjoint from the retained builder history.
  val Independent = s.owner == "review" implies s.replay.intersect(s.builderHistory).size() == 0
  val Safety = GrantedStore and NoPartialStore and Paced and KeptRefresh and OneRetry and NoFallback and Independent
}
