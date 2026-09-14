# Shaping prototype only

Observed result: 17 focused offline tests passed; the complete native compatibility
probe passed in 212.1 seconds. results.json retains concise facts. This includes
the actual native denial reaching the collector, exact resume and fixture Review.
No Build was started and no Intent was approved by those test agents.

These source and test copies are an unaccepted prototype, not production edits.
The controller incorrectly wrote them in the source tree during shaping, then
moved them here and restored the two pre-existing implementation files exactly
to their pre-edit Candidate bytes (c3963ae98a3e93616ba12b762abf565d8b8a23ba).
The new test was removed from test/. No broad Git reset or stash operation ran.

Prototype verification must use this directory or an isolated copy inside the
Intent, with separate build output. Do not copy these files into production as
part of shaping or claim they passed tests before actual probe evidence exists.

To reproduce against the recorded failed Candidate, run `python3 prepare_probe.py
/absolute/path/to/kogen` here. It checks the two baseline source hashes and creates
workspace/ entirely inside this Intent, including private dependencies/build output.
From workspace/, run:

```
mise exec -- mix test test/kogen/codex_denial_evidence_test.exs test/kogen/codex_compatibility_preparation_test.exs test/kogen/codex_compatibility_test.exs
mise exec -- mix test test/prototype_live_test.exs --include live
```

The second command performs bounded provider-backed work using the existing
selected Kogen login. It puts runtime fixtures inside workspace/, uses configured
native root/helper profiles, and runs only fixture-owned checks. It does not
install, authenticate, run a Build, or run the repository's aggregate gates.
Remove only this disposable workspace after retaining concise results; do not
include copied dependencies, compiled artifacts or private native streams in
the maintained Intent package. The prototype's source copies remain advisory
Build input and must be integrated/reviewed rather than copied blindly.
