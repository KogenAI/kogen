# Open questions

None requiring a product decision. The Shaper selected the managed Codex
runtime upgrade and GPT-6 route profiles, and explicitly settled that the
tracked `default_route` stays `claude`; Codex is selected by route name for
this Intent. The exact runtime target is the observed official `0.156.1`.

The previous approved Build stopped before paid verification; see
`failures.md`. Its stale reliability-catalog bindings are now included in the
Build's guarded scope so the Candidate can refresh source hashes and matching
remediation rows. The temporary working-tree default-route edit remains a
pre-Build cleanup condition.
