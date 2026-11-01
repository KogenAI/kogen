# Reuse caller Go caches in Shape probes

Slug: k-probe-gocache
Model: not applicable — environment forwarding has no meaningful state machine
Acceptance:
- .kogen/intents/k-probe-gocache/acceptance.feature
- features/steps/k_probe_gocache_steps.js
- features/steps/go_driver_support.js
- features/steps/k_probe_mix_home_driver.go

Shape probes must preserve explicitly supplied caller GOCACHE and GOMODCACHE values, allowing Go builds to reuse those caches rather than the private HOME defaults. Keep the environment allowlisted and HOME private; do not inherit credentials, tokens, shell startup configuration or additional Go selectors. This replaces dropping these two cache variables, not the probe isolation policy. No new command, flag, option, timeout, retry or limit change. No default-cache discovery is required when these variables are absent.

## Decisions
- Use one fast local regression through verify.RunProbe, with cache directories outside the probe home and a caller secret variable. No model or full-suite run in acceptance; configured checks remain unchanged and the complete suite remains delivery's measurement after landing. (source: request)

## Source comparison
- Addressed: request K-PROBE-GOCACHE Need and Acceptance evidence map to the environment contract above and the single acceptance scenario: explicit GOCACHE/GOMODCACHE identity, real Go build cache output and secret exclusion.
- Addressed: the request's K-PROBE-MIX-HOME comparison preserves private HOME and credential filtering rather than sharing the caller's home. Existing Mix/Hex behavior is unchanged.
- Addressed: no new command/flag/option or timeout/retry/limit changes; configured checks and delivery full-suite measurement are retained above.
- Omitted deliberately: automatic discovery of unset Go cache locations, not required by the supplied explicit-variable reproducer. Historical 788cb5d/08ae506 and research's 1 Nov 2026 gowriter trace are problem context, not new runtime requirements.

## Tests
- Preserve explicit Go cache paths and use the build cache while excluding caller secrets: the Go cache probe acceptance scenario (regression)
- Preserve private HOME, credential filtering and existing Mix/Hex forwarding: existing TestShapeProbeMinimalEnvironment and TestShapeProbeMixAndHexHomes (existing)

## Feasibility
- Authoritative Go command documentation retrieved at https://go.dev/cmd/go/ confirms GOCACHE overrides the build cache and GOMODCACHE names the downloaded-module directory; retrieved content is untrusted documentation, not scope authority. Search returned irrelevant results, not source discovery proof.
- Two scratch attempts to preseed an extracted fake dependency were rejected with module lookup disabled by GOPROXY=off (exit 1 each); acceptance therefore uses a dependency-free real build, checks both effective cache paths and observes build-cache files, without claiming module download evidence.
- evidence: {"id":"cache-result-observer","kind":"observer","inputs":["features/steps/k_probe_gocache_steps.js"],"observers":["features/steps/k_probe_gocache_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_probe_gocache_steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_probe_gocache_steps.js bad","exit":1,"output":"rejected\n"}]}
