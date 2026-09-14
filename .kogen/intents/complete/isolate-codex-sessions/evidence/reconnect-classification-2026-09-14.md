# Completed native turn rejected after reconnect warning

Build tanBMHWRfmfBF0LLc1pXWLV8 stopped without running live. Attempt 0 passed
Check for Candidate fb3c17584b9b3aadb2eba5a4a650553368065d6b, but the handoff cited
nonexistent lib/kogen/codex/discovery.py. The current file is
priv/kogen/codex/discovery.py. Attempt 1 reports provider_error for a reconnecting
broken-pipe error, with no Check or target receipt.

Observed native session 01a09caf-0c3f-7fe2-8ef0-d05ab3d44204 in the selected managed
scope records the initial task_complete at 21:38:37.114Z and the resumed turn's
task_complete at 21:41:53.737Z, following its task_started at 21:38:55.955Z.
No raw conversation was copied. Native completion does not prove a valid handoff,
matching Check, or acceptance; the exact stdout stream is not retained in this
tracking record.

Current lib/kogen/harness.ex parse_turn/3 first handles nonzero exit separately.
For exit zero it selects the first error or turn.failed anywhere in the stream
and rejects before checking its last turn.completed event. Thus an earlier
recoverable reconnect notification can reject an otherwise completed invocation.
The recorded provider_error establishes that the exit-zero parsing branch ran;
the retained native terminal independently establishes actual task completion.
Do not describe this solely as a provider outage or add blind automatic retries.

Within existing native verification preservation, distinguish transient stream
notifications from terminal provider failures. Before changing behavior, exercise
the actual Harness parser through a controlled executable with: error then valid
matching completion; error without completion; terminal turn.failed; nonzero exit;
missing or mismatched session; malformed final handoff; and truncated stream.
A completed turn still must satisfy all existing session, handoff, Check and Review
requirements. Never accept on native-log completion alone or ignore all errors.
Retain an invocation-bound structural receipt that permits this distinction without
copying private prompts or tool output. This is stream-result classification, not
a new retry/recovery feature or increased resumption allowance.

The Shaper supplied this failed Build after the previous audit. This note updates
the existing in-scope repair guidance; no source, test, configuration, approval,
baseline or budget was changed, and no Build was restarted. Repaired classification
has not yet been implemented or verified.
