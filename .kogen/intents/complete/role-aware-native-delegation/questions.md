# Resolved shaping decisions

## Required model configuration

On 2026-09-09, the Shaper accepted this exact topology:

```yaml
shaping:   {model: gpt-6-astra, effort: low}
developer: {model: gpt-6-astra, effort: low}
reviewer:  {model: gpt-6-astra, effort: low}
helpers:
  scout:  {model: gpt-5.6-luna, effort: low}
  worker: {model: gpt-5.6-terra, effort: medium}
  expert: {model: gpt-6-astra, effort: medium}
```

All profiles are required in `.kogen/config.yaml`, making effective model use
visible and consistent with the existing configurable roots. Configuration
does not require spawning: each root applies the delegation threshold in
`scenarios.yaml`. On 2026-09-09, the Shaper also accepted adaptive concurrency:
it follows worthwhile independent work and native harness capacity rather than
a Kogen-specific numeric cap. Nesting remains shallow by default. Ownership and
routing stay prompt policy.

Shaping owns consequential scope and contract quality, not merely chat
responsiveness. Smaller models save time and root context through bounded
delegation while Astra retains synthesis and final judgment. Astra-medium is
reserved for a named consequential uncertainty that benefits from independent
reasoning; it is not a routine escalation tier.

## Writable Developer helpers

Developer workers may make changes within explicitly assigned, non-overlapping
guarded paths after the root has stabilized the interface. The failed
live-repository isolation in the shaping probe was a controller test-harness
error, not evidence against writable helpers.

## Verification boundary after the first Build attempt

On 2026-09-09, the Shaper split verification-gate ownership into its own Intent;
`automated-verification-ownership` is now complete at commit `17f2f7e2`. This
Intent consumes that contract: Developers and their helpers do not run declared
verification targets, while the Stop hook and outer Build retain their existing
owners.

The first Build attempt also showed that adding broad provider-backed delegation
tests would pull in distinct work: the global `live` suite took roughly twelve
minutes, and the new rollout reader rejected Codex's observed
`custom_tool_call` representation while accepting only `function_call`.
Provider-backed delegation lifecycle coverage, rollout-schema compatibility,
durable target diagnostics, failed-Build recovery, and optional MCP isolation
remain separate Intents. This Intent uses `check` for deterministic config,
prompt, argument, and fake-lifecycle verification and retains the real native
agent probes gathered during Shaping as feasibility evidence.
