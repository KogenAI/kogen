# Shaping decisions

- **Codex route is upgraded independently of the repository default.** The
  human Shaper explicitly chose to keep `default_route: claude` and use the
  named `codex` route for this Intent. The temporary Codex-default checkout
  commit is operational residue and must be removed before Build.
- **Reliability catalog maintenance is in scope as evidence bookkeeping.**
  Changed catalog-covered tests require refreshed source hashes and matching
  remediation rows in `priv/kogen/test-reliability.yaml` and
  `priv/kogen/test-reliability-remediation.yaml`; otherwise `make check` rejects
  the Candidate as stale. This does not expand the feature behavior.
- **Native paid evidence remains required.** Existing artifact metadata and
  disposable model probes support the pin/profile choice but do not establish
  authenticated native compatibility. `make live-native` remains the narrow
  paid target for all three scenarios.
