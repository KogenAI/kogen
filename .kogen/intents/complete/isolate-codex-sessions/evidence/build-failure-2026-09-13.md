# September 13 failed Build: concrete repair guidance

Authority: after read-only diagnosis, the Shaper explicitly directed the controller
to add these findings and repair guidance to this Intent. This is an amendment
within existing approved requirements, not a new feature, new approval, extra
retry budget or implementation authorization. The package remains Approved.
The frozen input and record of the stopped Build remain unchanged.

## Observed result

Source: `.kogen/runtime/scenario-tracking/2n3r_14Dcx7ZSTplQ6PYvIkt/record.json`,
current failed-Candidate source, and the retained evaluation diagnostics below.
All three attempts passed their offline Check. Attempt 0 failed settlement because
its Check Candidate differed from the current tree. Attempts 1 and 2 failed live:
3/9 then 6/9 tests passed. No top-level accepting Review was reached. The list of
twelve unresolved scenarios is pending acceptance, not twelve independent failed
assertions. The stderr MCP/model-refresh/patch diagnostics supplied by the Shaper
are not established as the terminal cause.

## Confirmed defect 1: context serialization breaks public Shape capture

Final evaluation root:
`.kogen/runtime/shaping-evaluation-1789321329805-530/`.
`suite-failure.json` identifies csv-continuation exiting 1 and cancellation of the
other four cases with no cleanup errors. Its retained
`runs/csv-continuation/transport.log` reports Jason.Encoder cannot encode a Tuple.
The example is an ordinary RUSTUP_HOME environment pair. The case receipt records
an infrastructure error: Expect exited before the startup terminal completed.
This is not a semantic rejection of the shaped feature.

Source: `lib/kogen/codex/environment.ex`, retain_test_context/2, currently writes
Jason.encode!(context). Environment.prepare constructs context.env as a list of
Elixir tuples. `test/support/shaping_evaluation/managed_resume.py` consumes JSON
pairs with `for name, value in context["env"]`. The producer never reaches that
consumer because tuples have no default JSON encoding.

Repair the actual producer/consumer boundary with an explicit JSON-safe context
representation, keeping the selected absolute executable, argv and environment
semantics. JSON arrays of two-element pairs fit the existing consumer; another
representation is acceptable only if both sides and their tests change together.
Preserve absent/null versus empty versus set values, authoritative managed markers,
selected session scope and immutable snapshot lifetime. Validate malformed context
before exec; do not stringify arbitrary structs, drop environment entries, choose
personal PATH, or bypass the production serializer in the passing test.

Focused proof before another live attempt must exercise actual Environment.prepare
and receipt serialization with synthetic caller inputs, then the maintained Python
consumer using a harmless owned executor. Assert exact argv and environment,
set/empty/unset XDG semantics, stale/missing/malformed context rejection, exclusive
receipt creation, and no dispatch on invalid input. Run the combined driver
rehearsal through that real context boundary rather than supplying hand-authored
JSON that avoids the failing producer. Synthetic execution proves transport only;
normal live acceptance still proves real native behavior.

## Confirmed defect 2: semantic Reviewer caller lacks managed context

The final target receipt reports `{:error, "missing .kogen/config.yaml"}` at
`lib/kogen/harness.ex:308`, with_context/2, reached from
`test/kogen/live_test.exs:129`, review_semantic_candidate!/3.
The fixture changes cwd and calls the context-free Reviewer arity. The new Harness
then attempts to read Kogen configuration in that fixture instead of receiving the
already selected configuration/runtime/scope from its live owner.

Adapt this actual caller to prepare and pass explicit managed context from its
owning checkout, with fixture-specific discovery/session state and correct lifetime.
Keep both incomplete and corrected semantic candidates, independent Review,
negative controls, current configured profiles and owned receipt capture. Do not
invent missing configuration defaults, copy personal settings/credentials, exempt
this live case, or switch it to a fake provider to obtain a passing gate.

The focused regression starts in a realistic fixture without a tracked Kogen
configuration and executes the actual owner-to-Harness call path through an injected
native boundary. It must prove that the passed context prevents fixture-local
configuration resolution and that effective account/runtime/profile routing is
preserved. Native semantic Review remains part of the outer-owned live target.

## Remaining diagnostic: native helper fixture

`test/kogen/native_helper_live_test.exs` still changes cwd and invokes the
context-free Developer arity, then derives sessions from caller CODEX_HOME or
personal HOME. Its final evidence directory,
`.kogen/runtime/live-evidence/native-helper-68637-74-1789321329913562292/`, contains
only protocol.json and parent-prompt.md; no native receipt was produced.
The complete assertion for this case is outside the retained target-output tail.
Missing fixture configuration is a source-supported explanation, not a captured
third stacktrace. Confirm that path with a focused offline reproduction before
claiming the exact diagnosis settled.

Adapt the native-helper owner to pass its explicitly selected managed context and
actual session location, preserving its existing native metadata/profile assertions.
The original every-role-discovery and current-main reassessment already require
this. A receipt copied from another case or helper self-identification is not proof.

## Check settlement and evidence ownership

Attempt 0 consumed one resumption on a Candidate mismatch after a passing Check.
The record proves the mismatch, not which operation changed the tree. Inspect the
owned Candidate/check evidence before attributing it to a specific writer. Test
that newly generated files stay in owned ignored locations and do not mutate the
Candidate after Stop capture. Do not disable Candidate checks, clear Git flags,
reuse a stale Check or increase the two-resumption budget.

The final run's six passes are useful historical evidence, not cached gates for
a repaired Candidate. Developer may use focused non-gate tests; Stop owns check,
outer Build owns live, and fresh independent Review owns acceptance. Preserve the
existing full live set, exact runtime selection and required evidence manifest.
Do not launch a fresh full Build merely to discover these deterministic bootstrap
failures again. The Shaper retains the established stash/start/pop workflow.

## Scenario links and limits

These repairs implement existing release-pinned-runtime, every-role-discovery,
active-runtime-preservation, ordinary-tool-environment, verification-and-review
and regenerate-settings-preserve-state requirements. Existing guarded paths cover
the implementation and fixture files. No new public command, installer behavior,
account policy, broad configuration fallback or postponed scenario is introduced.

This amendment contains source inspection and retained failure observations only.
No repair code, focused reproduction, aggregate gate or provider call was run by
the diagnosing Shaping Controller. The future repair must supply that proof.
