# Shaping investigation

These are read-only investigations and a small isolated Git probe. They are not
Build acceptance evidence. No product implementation or verification gate was run
for this Draft.

## Baseline and provenance

The conversation was minted as Intent 01a084f6-0f8a-7f32-9e9a-4fd9c0769930 against
main at fdfaea11cdb2c1403974dc32737f78a818bf344b. The startup prompt did not supply a
literal started timestamp. The recorded start marker is the UUIDv7 mint time
(2026-09-09T06:58:33.482Z), decoded using Kogen.Intent's timestamp format, rather
than an invented wall-clock observation. The shaping profile records the codex /
gpt-6-astra / low launch configuration observed at the start of this conversation;
it is provenance from configuration, not independent provider-rollout attestation.

Initially the worktree contained unfinished role-aware delegation changes and an
Approved package but no Complete package. No such changes were discarded or claimed
accepted. On the final refresh, HEAD was
4d7a2402eb9b5941a2993a502e7ea1c6abac407b and tracked status was clean. Intervening
commits include automated gate ownership, removal of redundant commit prose,
role-aware delegation, isolated fast checks, and fresh-session Draft continuation.
The README and maintained check workflow were read before designing integration.

The delegation Complete package and evidence now exist. Its recorded acceptance
does not establish any additional routing guarantee beyond what actually landed.
Current configuration remains Astra-low roots, Luna-low scout, Terra-medium worker,
Astra-medium expert, and two outer resumptions. This Draft changes none of those.

The Shaping-continuation Complete evidence records passing check and live results,
including a real continued Draft and accepted Build. Its implementation preserves
original provenance. This Draft similarly preserves its original minted fields and
records the current investigated baseline separately; no new launch visit is invented
for a later turn in the same conversation.

## Motivating packages and preserved Candidates

The complete external-repository-cli Draft was read, including INTENT.md, scenarios,
questions, references, archive probe, config-ownership-review.md, and
incomplete-scenario-review.md. It remains unchanged and parked.

- Stash commit 27e46532f2703aef470f076637de2e5d754791e4: Kogen.Project lists config
  with bundled owned assets and uses the same expected-content comparison during
  later readiness. This confirms the first review's ownership-transition finding.
- Stash commit 44abfb6946605b7aa3585171d6d5e8a3db5cfa13: Kogen.Readiness checks
  config's working content using git status --porcelain. CLITest uses non-default
  role settings but only asserts Developer/Reviewer model strings, not all roles'
  models/efforts or invalid committed-config rejection. LiveShapeToBuildTest still
  rsyncs Kogen sources, shares dependencies, precompiles, and invokes Mix tasks.
  This confirms that the explicit revised scenarios still lacked full evidence.

The first recorded final Candidate/session were e3c3e69859d14c4508ef8ffdc0403709d609c9bf
and 01a0828c-7964-71e0-975e-faa394a44b4b. The second were
a13dd7b9c61122b33798e3e21b40758bc4d80529 and
01a08493-28a0-7e51-957f-678394cc6f68. Both exhausted two outer resumptions despite
passing Check. Review correctly prevented acceptance; this Draft addresses lost or
incomplete handoffs and makes all scenario assessments explicit.

## Current code trace

- lib/kogen/build.ex load_scenarios validates target lists and flattens them; it
  does not retain a scenario assessment model. Developer result is threaded into
  evidence_markdown and ignored. Rework forwards the latest joined finding strings.
- lib/kogen/harness.ex validates thread.started, session consistency, provider
  failures and terminal turn.completed. Both initial Developer and exact resume
  share run_turn and the event parser. Completed agent-message events are already
  available; the Reviewer fallback selects the last such message. This is a small
  existing transport seam for local Developer JSON handoff parsing, without new
  CLI flag assumptions.
- The current Reviewer schema contains only verdict and string findings. It has no
  scenario coverage or finding identity enforcement. An accept with empty findings
  is structurally sufficient today.
- lib/kogen/check.ex binds Check to Candidate and Developer session. Extra targets
  are independently run by Build, and the Candidate is compared after targets and
  Review. Check.invalidate! deletes current history after optional raw-log archive.
- lib/kogen/verification_policy.ex and the role prompts reserve Check to Stop and
  declared non-check gates to Build. The handoff must reference proof without
  requiring Developer execution or advance knowledge of those gate outcomes.
- lib/kogen/build.ex holds Approved entries and bytes in memory, separately from
  Git. Complete publication copies Approved, writes generated evidence, removes
  Approved, then verifies and commits the staged Candidate. Existing rollback must
  accommodate every generated tracking artifact without deleting user evidence.
- Normal raw streams and reviewer receipts require KOGEN_RAW_LOG_DIR. Current
  default runtime files alone are not cumulative scenario history. Runtime is
  already ignored by .gitignore; no new ignore rule is necessary.

## Real Git probe

A temporary standalone Git repository was initialized and committed with a config
file containing seed bytes. For each flag, the probe set the real index flag,
changed the working file, then ran status, add -A, and write-tree:

```text
assume-unchanged '' tree equals HEAD: True disk differs: True
skip-worktree '' tree equals HEAD: True disk differs: True
```

The repository was removed after the probe. No project index flags were changed.
Both Kogen.Git.candidate_id and the tracked shell Stop hook copy the real index
before add -A, so agreement between their hashes shares this blind spot. A bounded
rejection rule is proposed rather than implementing sparse-index normalization.

## Native investigation and independent challenge

Read-only Terra-medium helpers separately traced closure/output handling and
recovery state. An Astra-medium helper challenged Candidate identity and later
the specific finding-transition contract. Helpers received bounded packets with
fresh context and no Draft-writing or product-decision authority. All completed;
the root authored this Draft and owns its scope and approval.

The closure refresh confirmed that selecting the final completed agent message
works at the same code seam for initial and resumed turns. Real provider behavior
for the new contract is still a required live Build proof, not claimed here.

The independent challenge recommended separating Candidate-specific scenario
assessment from durable finding history, validating all Review dispositions before
applying any, and requiring one disposition for every open finding. A complete
record can still describe weak tests, so a real semantic negative control is needed
in addition to schema/transition tests. Those recommendations are reflected in the
Draft; helpers did not approve it.

Recovery research found in-memory-only lifecycle state and a self-hosting restart
compatibility question. The Shaper subsequently moved recovery to a separate Intent.
No lock, restart, journal-consumption, or retained-runtime mechanism from that
research is included here. In particular, a runtime tracking file is not a promise
that an exhausted Build can be resumed.
