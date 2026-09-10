# Shaping decisions and remaining approval

## Accepted scope decisions

The same-conversation Shaper initially requested scenario tracking together with
exhausted-Build continuation. After discussing the distinction, the Shaper explicitly
said to work here on tracking scenarios and start a separate Build-resuming Intent.
The latest instruction is to finish this scenario-tracking Draft. That supersedes
the original combined-scope requirement; it is not approval of this package.

- Scenario tracking spans Shaping, Developer handoff, owned verification,
  independent Review, existing in-process rework, and retained outcome evidence.
- Build restart/resumption is being shaped separately. This record is not a
  checkpoint, and its existence authorizes no future continuation.
- Automatic worktrees are out of scope.
- external-repository-cli remains parked with its complete outcome and
  provider-backed proof intact. Neither stash is to be applied by this Build.
- Existing model/helper routing and verification ownership are the baseline.

## Approved contract decisions

The contract in INTENT.md proposes an optional scenario-linked risks file (legacy
packages stay valid), structured role responses, fail-closed handling of Git index
flags that hide Candidate changes, and failure diagnostics identifying unresolved
scenarios and the retained record. There is no new CLI command or automatic return
to Draft. The Shaper's subsequent explicit approval settled these behaviors together.

Current HEAD is 4d7a2402eb9b5941a2993a502e7ea1c6abac407b, rather than the original
minted baseline. The Shaper reported the intervening Shaping-continuation work
complete and asked to finish this Intent. The Draft preserves original provenance
and explicitly records the current investigated baseline; approval must be of this
current-baseline contract, not an imagined bootstrap-only implementation.

No unresolved product question is silently delegated to the Developer. Wire-field
names and internal record basenames may follow implementation conventions, provided
the explicit coverage, ownership, validation, retention, and failure behavior hold.

## Approval and next step

After inspecting the Draft summary and receiving an explanation of the introduced
behavior, the Shaper explicitly replied “approved” in this same conversation.
That approves this current-baseline package, including the scenario-tracking scope
and its separation from Build resumption. The whole directory was moved to
approved/track-approved-scenarios. No Build has been run as part of approval.

To implement the approved package, run `mix kogen.build track-approved-scenarios`
from a checkout satisfying the current Build preconditions.
