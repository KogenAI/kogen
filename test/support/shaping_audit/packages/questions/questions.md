## Ask the Shaper

1. Should the report be shown in a web dashboard? Recommendation: no, keep it a file. Evidence: unproven — no dashboard exists yet.
2. Should hook-state.json count blocks per session id or per process? Recommendation: per process. Evidence: `lib/kogen/shaping_audit/stop_hook.ex:1`
3. Does plain Kogen always require explicit human approval of each Intent? Recommendation: yes, unchanged. Evidence: unproven — asking whether this is already decided.
4. Which harness should the auditor use on a route without an explicit auditor entry? Recommendation: the adversarial harness, as on hybrid routes. Evidence: unproven — a related but distinct question from the shipped auditor-profile decision.

## Settled

1. The package's own settled decision. Evidence: docs/note.txt:1
