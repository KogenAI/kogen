# Build-failure lessons from the 2026-09-25 batch: input to the Shaping audit (#3)

Each lesson is a real failure from today's batch, the Shaping miss behind it, and the check
that would have caught it before a Build. "Det" is a deterministic rule, "Aud" is an
adversarial-auditor instruction, and "Jev" is a Jev question.

1. **Producer→consumer closure for new artifacts** (Build o-DlRi, #2). #1 added record-version
   sidecars (a new artifact next to record.json). The live fixtures' evidence-retention code
   (`preserve/3` in test/support/live_reviewer_rework_fixture.ex, `preserve_tracking` in
   test/kogen/live_shape_to_build_test.exs) copies only record.json, and `Evidence.resolve/2`
   then failed after the fixture was deleted. Neither #1's audit nor #2's Sol re-audit saw it.
   - Det: when a Draft's affected lib module writes or changes a persisted artifact (a record,
     summary, manifest or sidecar), list every repository file that copies, reads or resolves
     that artifact (grep the artifact's path fragments and function names across lib/, test/support
     and test/). Flag each one not in affected_paths as `artifact-consumer-not-covered`.
   - Aud: "Trace every file or format the change creates through all consumers, including
     retention, copying, archival, resolution after cleanup, and live fixtures."
2. **Runtime path assumptions under isolated test code** (o-DlRi cycle 2). A new preflight used
   `Application.app_dir/priv`, but the live test runs from a `kogen-test-code-*` copy with no
   `priv/` (and Erlang mis-resolves the lib dir). Aud: "Does any new code path read priv/ or
   app files at runtime inside tests that run from the isolated code copy?" Det (advisory):
   the Draft touches test/support live fixtures and lib code using `Application.app_dir` or
   `:code.priv_dir`.
3. **Environment readiness of paid targets** (#2 first start). The shared Kogen Codex scope was
   broken (an unexpected `plugins/` cache written by an outside tool), which would have failed
   live-native and the Codex Reviewer mid-Build. Det: for each selected paid target's harness,
   run the same readiness check Build and the live owner use (`kogen.codex.status` /
   `kogen.claude.status` semantics) at audit time. Report `environment-not-ready` as blocking
   with the exact reason.
4. **Reviewer verdict completeness** (Build qWusXkQn, #1). An accepting Reviewer omitted one of
   7 scenario ids, and the Build stopped as malformed. Aud/Det (advisory): large scenario sets
   and long `then`s raise the omission risk. Prefer fewer, sharper scenarios. (The controller fix,
   one bounded re-ask, belongs to the failure-handling Intent.)
5. **Baseline moved after a predecessor lands** (#2 re-audit). #2's evidence cited #1-era
   anchors (`cited_bytes`, old lines) that no longer existed. Det: `shaped_against.head` ≠ HEAD
   → re-verify every cited file:line and function name at HEAD, and flag `stale-anchor` per
   miss (blocking when a scenario, proof or guarded path depends on it).
6. **Live fixture wiring for a new route** (#2 re-audit). The Draft pinned the hybrid route for
   the nested Build, but the fixture still loaded default-route profiles, audited Claude only,
   and had no Codex login preflight. Aud: "For every live target selected, walk its fixture:
   which route, profiles, login scopes and preflights does it use, and does the Draft change
   them consistently?"
7. **Fast-fail preflights before paid dispatch** (good pattern seen). A readiness check that
   fails in 0.3 s before any provider call saved a paid run. Aud: require live fixtures touched by
   the Draft to verify prerequisites (login scope, runtime, paths) before the first provider call.
8. **Stale objection after a later passing cycle** (kdUszVF4). This is fixed in #1. Aud: a
   scenario whose proof relies on a paid target with known variance needs its failure handling
   stated.
9. **Deferred wide change hidden in a narrow Intent** (#2, default-route flip). Flipping
   `default_route` changes what every general live target runs on, and edited live owners force
   extra paid targets (D8). Det: an affected path that is `.kogen/config.yaml`'s `default_route`, or
   an edited live owner file, must map to its catalog target in `verified_by`.
10. **Tool hygiene in audits.** Sol/Astra runs outside Kogen must pass Kogen's disable flags
    (`--disable apps --disable plugins --disable shell_snapshot`) and must never run while a Build
    uses the same scope. Record this for any audit layer that launches a harness: it must use
    Kogen's own launch path, never a raw binary against the shared scope.
