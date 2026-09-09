# Enforce automated ownership of verification gates

Approved by the human Shaper in this conversation. Start with the accepted scope below, then
[scenarios](scenarios.yaml) and [probe evidence](evidence/preexecution-probe.md).

## Problem and outcome

Developers currently receive permission to run non-check gates for early signal.
Remove that permission. Automated Kogen machinery owns every verification gate.
Developers, including their delegated helpers, must not invoke `make check`,
`make live`, the Stop-hook script, or any Make target in the selected Approved
Intent's `verified_by` lists, including for early signal. Focused non-gate tests
remain allowed. Developers must not invoke gates indirectly or edit their
verification records. Runtime blocking covers the explicit command forms below;
it is not a universal process sandbox.

## Accepted decisions

The human chose option 1A and option 2B in this shaping conversation:

- Stop owns `check`; outer Build owns non-check targets.
- Actual runtime prevention before command execution is required. Prompt-only
  rules and post-execution detection are insufficient.

The human then chose the small Build ("for now I guess the small build"):
bounded prevention of explicit commands, with indirect execution still forbidden
by the Developer contract. The human subsequently approved the complete bounded Draft with an explicit "yes" in this conversation.

## Ownership and timing

Preserve the existing schedule and prove it with deterministic fake fixtures:

1. Every Developer Stop attempt runs the Stop-owned `check`. Failure blocks
   in-conversation; it does not trigger expensive non-check targets.
2. Outer Build accepts only Check evidence matching the settled candidate and
   Developer session. It does not rerun `check` itself.
3. After that settlement, outer Build runs distinct non-check targets in first
   scenario occurrence order, once each for that outer attempt. Stop at the first
   failure and do not Review until all declared gates pass.
4. An outer rework (target failure, invalid Check settlement, or Reviewer finding)
   resumes the same Developer session within the existing budget. Fresh Check
   evidence is required, then the non-check sequence starts over. No cross-attempt
   caching, even when rework produces no file changes.
5. Automated hook and outer invocations remain permitted. A blocked Developer
   tool request must not run a gate or produce passing verification evidence.

## Runtime blocking contract

Use the supported Codex PreToolUse denial path for covered Developer commands;
probe evidence establishes denial before shell execution under existing flags.
Use one normalized prohibited target set: `check`, `live`, and the union of all
selected scenario targets. Apply the same policy to launch and every resume;
repeat the ownership instruction and concrete target list in resume feedback.
Make the diagnostic explain that machinery owns the gate and focused tests are
allowed. Keep the prohibition applicable to delegated work.

Tests must execute the production policy through a fake tool-dispatch path,
including negative controls which fail if a denied gate actually creates its
marker. Merely searching prompt text or fabricating a rejection is insufficient.
Keep simulated harness Stop invocations distinguishable from Developer requests.
Use harmless fixture targets and counters rather than the expensive live suite.

### Covered commands

Intercept Developer Bash tool requests before execution. Match executable and
argument tokens, not substrings in prose. Cover:

- Direct `make <gate>` and path-qualified make, such as `/usr/bin/make check`.
  Gate names include `check` and `live` even when undeclared, plus every selected
  scenario target. Handle multiple goals, literal quoting, whitespace, leading
  environment assignments, and ordinary Make options such as `-C`, `-f`, and `-j`.
- The same explicit invocations in shell command lists joined with newline, `;`,
  `&&`, `||`, or `|`. Reject the entire tool request before any part executes.
- Direct execution of `.codex/hooks/check.sh`, its `./` or absolute path form,
  and a literal script-path argument to `sh`, `bash`, or `zsh`.

Focused commands such as `mix test test/kogen/intent_test.exs` remain allowed.
Reading or quoting a gate name is allowed (for example `echo 'make check'`).
Non-gate Make targets are allowed; this guard does not inspect their dependencies.

### Policy lifecycle and failures

Derive the target set from the selected Approved package before launch and use
it for every resume. The hook applies to Developer tool requests, including
native helper requests reaching the inherited hook path. Propagate the same
prohibition in delegation instructions; test helper-context hook dispatch.
Do not permit a command-local `KOGEN_ROLE=...` assignment to exempt a request.
Shaping and Review do not acquire gate ownership from this change. Actual
harness Stop callbacks and outer Build subprocesses are not Developer tool
requests and must continue to work normally.

If required policy data or the expected Bash command field is missing/invalid,
return a supported denial with a useful diagnostic, not an empty allow result.
Catch policy evaluation errors and deny. Build must fail preflight if required
hook registration or policy files are absent; do not silently launch unguarded.
The diagnostic should say that Kogen machinery owns verification and that
focused non-gate tests remain available. Do not introduce a new CLI or approval
prompt. A denied tool call can be corrected within the current Developer turn.

### Explicit limits

This Build does not resolve commands constructed through variable expansion,
command substitution, aliases, shell functions, `eval`, interpreter programs,
`sh -c` strings, wrapper scripts, Make dependencies, or later `write_stdin`
input. It does not recursively inspect executable contents or unknown tool
schemas. Uncovered command forms retain ordinary execution behavior; the prompt
still forbids using them to run gates. Runtime hook failure outside the policy
process (for example harness timeout), policy tampering, and specialized tools
that bypass hooks are not made into a hard security boundary by this Intent.
Do not present this bounded guard as preventing all indirect execution.

Use a small, deterministic tokenizer/classifier for the covered forms; do not
expand variables or run commands to classify them. Add table-driven cases for
covered forms and allowed lookalikes. Avoid growing this into a general shell
interpreter or execution-isolation project.

## Appetite and non-goals

One Build, one Developer conversation, two configured outer resumptions. No live
suite redesign, failed-Build recovery, model routing changes, new gate scheduling
options, or production website changes. A comprehensive execution isolation
redesign would require narrowing this Intent with the Shaper first.

## Verification and documentation

All scenarios use existing `make check`. Add offline production-policy and
fake-lifecycle tests for blocked attempts, allowed focused tests, ownership,
deduplication, order, failure, and rework. Update README's existing workflow owner
with the accepted schedule and precise blocking coverage; do not claim more than
tests and the native probe establish. The Developer does not run these gates;
the automated Stop and Build owners run them.
