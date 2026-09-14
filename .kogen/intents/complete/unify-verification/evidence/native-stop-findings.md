# Native Stop response probe

Executed on 2026-09-14 with installed codex-cli 0.154.0, configured Developer model gpt-5.6-sol at low. README names 0.153.4 as the prior verification target; this probe establishes 0.154.0 behavior only and does not impose a new minimum version. Both calls used existing account access successfully. An unrelated MCP authentication warning appears in stderr; it did not prevent these provider turns and is not evidence of a provider outage.

## Question and source relationship

Can a Stop callback allow two failed verification cycles to continue, then terminate on the third without another model continuation? Current .codex/hooks/check.sh only emits decision:block for every failure; lib/kogen/harness.ex:404 uses synchronous System.cmd and has no separate threshold interruption mechanism. The official Stop contract supports continue:false: https://learn.chatgpt.com/docs/hooks (retrieved 2026-09-14).

`probe_stop.py` retains the complete executable probe, exact argv, inputs and fixture generation. `native-probe-summary.json` records outcomes and source hashes. Each native-* directory retains the hook, Makefile, gate, raw stdout/stderr, and every hook input/output. Git metadata was removed after child exit; no external temporary dependency is needed to inspect evidence. The driver is experiment-only, not a proposed production hook.

## Observed results

- exhaust: check passes and toy live fails on each of three invocations; first two hook responses block with feedback; third returns continue:false. Exactly three model messages and three Stop calls, then turn.completed and process exit 0. No fourth invocation.
- pass-third control: check passes each time; toy live fails twice and passes third. Exactly three Stop calls, then turn.completed and exit 0; third hook response is continue:true.

Therefore provider exit 0 and turn.completed do not distinguish exhaustion from successful verification. The Build consumer must prioritize the fresh bound terminal exhaustion receipt over handoff parsing or generic resumption. The production hook must persist that receipt before returning continue:false.

## Limits and verification still required

This probes installed native callback semantics and sequential harmless Make targets. It is not production budget accounting, evidence forwarding, timeout handling, Review, or the new combined public Build route. No production source was modified. The later implementation must first rehearse the changed public controller with its actual hook under deterministic fixtures, then exercise native public lifecycle under live. Do not substitute this probe for those acceptance tests.

The native probe's two cases used 39.85 seconds of provider process wall time combined, excluding root preparation, tools, and helper work; this is not a complete-task performance claim. Raw usage remains in each stdout stream.
