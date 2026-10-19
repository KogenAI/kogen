// Original evidence (executed or exact existing evidence reuse) is not candidate validation.
// One protocol owner permits one active probe; independent HTTP jobs may overlap.
module faster_shaping {
  var phase: str
  var pending: int
  var done: int
  var failed: int
  var prevDone: int
  var eligible: bool
  var checked: bool
  var merged: bool
  var writes: int
  var approved: bool
  var originalEstablished: bool
  var originalReused: bool
  // Only existing full protected-baseline/HEAD evidence validity; not runtime equivalence.
  var exactEvidenceValid: bool
  var activeProbes: int

  action updateState(p, n, d, f, e, c, m) = all {
    phase' = p, pending' = n, done' = d, failed' = f, prevDone' = done,
    eligible' = e, checked' = c, merged' = m, writes' = writes, approved' = approved,
  }
  action keepOriginal = all {
    originalEstablished' = originalEstablished, originalReused' = originalReused,
    exactEvidenceValid' = exactEvidenceValid,
  }
  action init = all {
    phase' = "idle", pending' = 0, done' = 0, failed' = 0, prevDone' = 0,
    eligible' = false, checked' = false, merged' = false, writes' = 0, approved' = false,
    originalEstablished' = false, originalReused' = false, exactEvidenceValid' = false,
    activeProbes' = 0,
  }
  action establishOriginal = all {
    phase == "idle", not(originalEstablished),
    nondet evidenceValid = Set(true, false).oneOf()
    all {
      // On a miss, a normal scratch check establishes the original instead.
      originalEstablished' = true,
      originalReused' = evidenceValid,
      exactEvidenceValid' = evidenceValid,
      activeProbes' = activeProbes,
      updateState(phase, pending, done, failed, eligible, checked, merged),
    },
  }
  action dispatch = all {
    phase == "idle",
    nondet n = 0.to(4).oneOf()
    nondet optIn = Set(true, false).oneOf()
    nondet brief = Set(true, false).oneOf()
    nondet revision = Set(true, false).oneOf()
    nondet disjoint = Set(true, false).oneOf()
    val ok = optIn and brief and revision and disjoint and n >= 1 and n <= 3
    all {
      updateState(if (ok) "running" else "idle", if (ok) n else 0, done, failed, ok, checked, merged),
      keepOriginal, activeProbes' = 0,
    },
  }
  action beginProbe = all {
    phase == "running", pending > 0, activeProbes == 0,
    activeProbes' = 1, keepOriginal,
    updateState(phase, pending, done, failed, eligible, checked, merged),
  }
  action endProbe = all {
    phase == "running", activeProbes == 1,
    activeProbes' = 0, keepOriginal,
    updateState(phase, pending, done, failed, eligible, checked, merged),
  }
  action settle = all {
    phase == "running", pending > 0, activeProbes == 0,
    nondet success = Set(true, false).oneOf()
    all {
      updateState(if (pending == 1) "returned" else phase, pending - 1,
        done + (if (success) 1 else 0), failed + (if (success) 0 else 1), eligible, checked, merged),
      keepOriginal, activeProbes' = activeProbes,
    },
  }
  action cancel = all {
    phase == "running",
    updateState("stopped", 0, done, failed + pending, eligible, false, false),
    keepOriginal, activeProbes' = 0,
  }
  action integrate = all {
    Set("idle", "returned").contains(phase),
    updateState("integrated", pending, done, failed, eligible, false, true),
    keepOriginal, activeProbes' = 0,
  }
  action readiness = all {
    phase == "integrated", merged,
    updateState("ready", pending, done, failed, eligible, true, merged),
    keepOriginal, activeProbes' = 0,
  }
  action correctCandidate = all {
    phase == "ready",
    updateState("integrated", pending, done, failed, eligible, false, true),
    keepOriginal, activeProbes' = 0,
  }
  action publish = all {
    phase == "ready", checked, merged, pending == 0,
    updateState("published", pending, done, failed, eligible, checked, merged),
    keepOriginal, activeProbes' = 0,
  }
  action stay = all {
    updateState(phase, pending, done, failed, eligible, checked, merged),
    keepOriginal, activeProbes' = activeProbes,
  }
  action step = any { establishOriginal, dispatch, beginProbe, endProbe, settle, cancel,
    integrate, readiness, correctCandidate, publish, stay }
  val Bounded = pending >= 0 and pending + done + failed <= 3
  val DispatchGuard = Set("running", "returned", "stopped").contains(phase) implies eligible
  val EvidenceRetained = done >= prevDone
  val PublicationGuard = phase == "published" implies (checked and merged and pending == 0)
  val NoWorkerAuthority = writes == 0 and not(approved)
  val OriginalNotCandidate = (originalReused implies (originalEstablished and exactEvidenceValid)) and
    (phase == "integrated" implies not(checked))
  val OneOwnerProbe = activeProbes >= 0 and activeProbes <= 1 and
    (activeProbes > 0 implies phase == "running")
  val Safety = Bounded and DispatchGuard and EvidenceRetained and PublicationGuard and
    NoWorkerAuthority and OriginalNotCandidate and OneOwnerProbe
}
