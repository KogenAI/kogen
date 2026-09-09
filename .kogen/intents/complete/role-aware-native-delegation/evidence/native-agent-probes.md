# Native-agent probes

## Child identity and effective model

A bounded Codex probe explicitly spawned a `gpt-5.6-luna` child at low effort
with `fork_turns: none`. The parent rollout recorded `SubAgentActivity` started
and completed events with a child thread id. The child rollout's
`turn_context` recorded model `gpt-5.6-luna` and effort `low`.

`codex exec --json` did not include the spawn event in its ordinary stdout even
though the saved rollout did. Live verification therefore needs to capture the
root session identity and inspect the exact saved parent and child rollouts;
console prose is not evidence of delegation.

The tiny read probe incurred substantial fixed context overhead, confirming
that helpers must not be spawned for trivial lookups.

## Developer child and Stop-hook ownership

A second bounded probe launched an Astra-low root with `KOGEN_ROLE=developer`
and an explicitly assigned Terra-medium child. The child created one assigned
file and completed; only the root session produced the Kogen Verification
Record observed in `verification-history.jsonl`. This supports a root-only
Check contract when all children finish before root Stop.

The probe runner accidentally launched Codex from the real checkout rather
than the disposable clone it had prepared, while another Kogen Build was
active. This was a controller/setup error, not a failure by the Developer
child: the child followed its assignment and touched only its assigned file.
The probe-created file was removed immediately, and the exact transient
verification record/history entry produced by the probe was reverted to the
prior Build's record without touching that Build's code changes.

The location mistake is not evidence against writable helpers. The positive
behavior observed in the probe supports allowing bounded Developer writers:
exclusive path ownership, completion before root integration, root inspection
of their diffs, and a root-only settled Check remain the required safeguards.
Those are normal shared-worktree coordination rules, not mitigations for this
probe error. A replacement live probe must run in a disposable clone and assert
its current working directory and Git worktree root before Codex starts.
