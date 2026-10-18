# 02 Shaping

`kogen intent shape <slug> <file|->` turns a request into an **Intent**: short prose, executable Gherkin with its step definitions, and a Quint model when the change has meaningful state or interacting rules (not for copy changes or plain wiring). The shaper makes the requested behavior precise, proves its risky technical assumptions with quick throwaway probes, asks the caller about material UI/UX choices, chooses straightforward technical details itself, and adds only what the requested behavior needs. It never approves and never builds.

## The Intent

`.kogen/intents/<slug>/` holds `intent.md`, `acceptance.feature` and, when needed, `model.qnt`. Step definitions live in step files under `commands.acceptance.steps_dir`: existing files that are reused or edited, or new ones.

```markdown
# Add an is-even helper

Slug: is-even
Model: not applicable — a pure function without state
Acceptance:
- .kogen/intents/is-even/acceptance.feature
- features/steps/is_even_steps.js

calc.is_even(n) returns True for even integers and False for odd ones; non-integers raise TypeError.

## Decisions
- Non-integers raise TypeError instead of returning False. (source: answer 1)

## Tests
- calc.is_even returns True for even and False for odd integers: add test_is_even in tests/test_calc.py (unit)
- calc.is_even raises TypeError for a non-integer: add test_is_even_rejects_floats in tests/test_calc.py (unit)

## Feasibility
- `1.5 % 2` returns 1.5 in python3 instead of raising, so is_even checks the type itself. (probe 1: exit 0, 0.1 s)
```

`## Tests` lists, for each behavioral rule the request adds, changes or removes, the test to update or add, chosen by the table of `docs/testing-rules.md` (SET-6): one line `- <rule>: <test to add or update> (<layer>)`, where `<layer>` is `unit`, `integration`, `scenario`, `regression` or `existing`; or `- none: <reason>` for a change with no executable behavior (copy, documentation).

With a model: `Model: .kogen/intents/<slug>/model.qnt invariants=<Name>[,<Name>...] seed=<n> samples=<n> steps=<n>`.

## Requirements

**SHP-1 — Input.** The slug matches `^[a-z0-9]+(-[a-z0-9]+)*$`, 3–48 characters (`intent/invalid_slug: Slug must be 3 to 48 characters and use lowercase letters, digits and dashes.`, exit 2). The request comes from a file or stdin (`-`), is read by the `kogen` command and passed as protocol data, never in argv. Empty, missing or unreadable input is `intent/request_unavailable: <stdin|abs path>: <empty|not found|unreadable>` (exit 2). When the request file is untracked inside the repository, shaping prints `note: <path> is untracked; commit or move it before kogen intent build`. The command blocks until shaping ends.

**SHP-2 — Preconditions.** Before any model request shaping refuses: an uninitialized project (`environment/not_initialized: <path> has no .kogen/project.yaml; run kogen init`, exit 3), an invalid configuration (SET-4), an unset `commands.acceptance.run` or `commands.acceptance.steps_dir` (`environment/acceptance_unconfigured: set commands.acceptance in .kogen/project.yaml`, exit 3), a missing tool (LOOP-12), no login (GPT-5), a slug that is already shaped (`intent/exists: <slug> is already shaped; edit its files, or delete .kogen/intents/<slug>/ and shape again`, exit 5), and, right before the first request, a failing `commands.setup` (`environment/setup_failed`, as in AUT-5, exit 3), then a configured command whose program is missing (LOOP-12), then an acceptance command that does not start: it runs once on a feature with no scenarios, as in SET-13, and must exit 0 and write its report, else `environment/acceptance_unavailable: <reason>; fix commands.acceptance.run in .kogen/project.yaml` plus the start and end of its output (exit 3). So a broken environment costs no model time. While `commands.checks` is empty, shaping prints `warning: commands.checks is empty; Builds will not run your tests` on stderr.

**SHP-3 — Context.** The shaper receives the request, the root `README.md`, the tracked file list, the configured commands, the Intent format and rules of SHP-6, the text of `docs/testing-rules.md` (SET-6; its section 6 is how the shaper specifies the change), and the text of every existing step file in `steps_dir`, with the instruction that its Gherkin may only use sentences those files or the step files it writes define. It has read-only tools `read_file`, `list_files` and `search_text` (paths are resolved against the repository root) and the `probe` tool (SHP-10). It cannot write project files.

**SHP-4 — Submission.** The shaper ends by calling `submit` with either `questions` or `files`. An invalid submission goes back with its problems and writes nothing. A valid submission is written, then the project's fixers (`commands.fix`, in order, progress `kogen: running fix-<n>: <command>`) run once in the repository root, so the Intent's files are formatted as the project formats files. The fixers' changes to the submission's files are kept: the card, the approval hash and the Build's checks on the unchanged tree see the formatted files, and the Build's own fixer rounds find nothing left to change in them. What the fixers change anywhere else is undone. The files are then checked for readiness (SHP-8); if they find problems, those go back to the shaper in the same way, and its next attempt overwrites the files written before. After a not-ready attempt the shaper may also ask questions (SHP-6); the files of that attempt stay. Invalid and not-ready submissions share one counter: at the third failed submission in a row shaping stops (exit 1). After an invalid one it prints `shape/invalid_output: the shaper's output was not a valid Intent after 3 attempts` plus the last problems. After a not-ready one it prints `intent/not_ready` (SHP-8), and the files of that last attempt stay. Files may only be the Intent's own files and step files under `steps_dir`, new or existing: shaping may prepare edits to existing step files, which the caller reviews with the Intent before approval and which are then fixed for the Build (VER-1). Every shaping progress line includes elapsed whole seconds since shaping started; a model request is printed as `kogen: shaping (request 2, 95 s)`.

**SHP-5 — Intent rules.** An Intent is valid when: `intent.md` has a title of at most 50 characters without a final period (it becomes the commit subject, and 50 characters is the common limit commit-message hooks enforce), `Slug:` equal to the folder, a `Model:` line, a non-empty `## Tests` section whose every line has the form above, and an `Acceptance:` list starting with its `acceptance.feature` whose paths exist and are not ignored; every `## Decisions` item names its source (`request` or `answer <n>`); a `## Feasibility` section lists each probe the shaper ran (or `- none`) with what it showed and its result (SHP-10); `acceptance.feature` parses (VER-3), every scenario has a `Then` step and none is tagged `@skip`, `@wip`, `@pending`, `@manual` or `@ignore`; a named model typechecks and its invariants exist. A model is required only when the change has meaningful state or interacting rules, never for copy changes or plain wiring; with `Model: not applicable — <reason>` the shaper says why. Problems print `intent/parse: the Intent cannot be read` or `intent/lint: the Intent needs changes` with one indented line each (exit 1). For a change to the acceptance runner or a step library, the Intent's scenarios exercise it through an independent harness listed in `Acceptance:`; the files that implement the requested change stay editable.

**SHP-6 — Questions.** The shaper asks only about material UI/UX choices the request leaves open; it decides technical details itself. Questions write no Intent file (files of an earlier not-ready attempt stay, SHP-4), are stored under `.kogen/local/shaping/<slug>/`, and print (exit 5):

```
Questions for is-even:
1. What should is_even do with a non-integer?
   a) raise TypeError (recommended)
   b) return False
Answer one per line as <n>: <letter or your words>, e.g. printf '1: a\n' | kogen intent shape is-even -
Or enter all: recommended to use every question's recommended option.
```

While questions are pending, the next `kogen intent shape <slug> <file|->` reads answers from the file or stdin (`-`), one per line as `<n>: <answer>` where the answer is an available option letter or free text — typed by a person or written by an agent alike. If no parsable answer line is present, it refuses with `intent/answers_invalid: expected one or more lines as <n>: <letter or your words> (or all: recommended)` (exit 2). A letter that is not an option for that question is refused with `intent/answer_option_invalid: question <n> has no option <letter>` (exit 2). The special input `all: recommended` answers every pending question with its marked recommended option. Pending questions are answered before anything else, even when files of a not-ready attempt exist (SHP-2's `intent/exists` does not apply). Unanswered questions are printed again (exit 5) without a model request. Answered questions, the request and earlier rounds go to the shaper, which may ask again. Deleting `.kogen/local/shaping/<slug>/` discards pending questions.

**SHP-7 — Never authorizes, never invents.** Shaping writes no approval and starts no Build. Every UI/UX decision in `## Decisions` names where it came from (SHP-5); whether the prose quietly decides something else is for the caller's review (AUT-1).

**SHP-8 — Readiness.** After writing the files Kogen checks: the SHP-5 rules; the model (`quint typecheck`, `quint test`, and one `quint run` per named invariant with the stated seed and bounds, VER-5); and a dry run (`commands.setup`, then the acceptance command on this Intent, VER-3) that must account for every scenario exactly once as `passed` or `failed` — any `undefined`, `pending`, `skipped`, `ambiguous`, missing, duplicate or unexpected scenario is not ready. Binding readiness is checked separately from the scenario result: every undefined or ambiguous step rejects readiness even when an earlier assertion in that scenario failed. Defined downstream steps skipped because an assertion failed are allowed. Ready (exit 0):

```
Intent: {abs:.kogen/intents/is-even/intent.md}
Acceptance test: {abs:.kogen/intents/is-even/acceptance.feature}
Step files: features/steps/is_even_steps.js (new)
Model: not applicable — a pure function without state
Scenarios: 3 (3 fail now, 0 pass now)
shape {model}/{effort} input={n} cached={n} output={n} reasoning={n} wall_ms={n}
Next: kogen intent approve is-even
```

Not ready: during shaping the problems go back to the shaper (SHP-4). When shaping stops, and for `kogen intent approve`, Kogen prints `intent/not_ready: the Intent is not ready to build` with one line per problem, naming file, line and step text for undefined steps (exit 1); the files stay for the caller to fix or delete.

**SHP-9 — Provider failures.** A provider error stops shaping with the `provider/…` line and the agreed `shape/provider_failed` sentence (CLI-6, exit 4); the failed request wrote no files (files of an earlier not-ready attempt stay, SHP-4). The sentence tells the caller to fix the provider issue and rerun with the same input: it names the request file path when a file was used, or says to pass the original request on stdin (`-`) and the same answers when questions are pending.

**SHP-10 — Feasibility probes.** While shaping, the shaper proves the risky assumptions the Intent depends on — that a library call behaves as assumed, a tool or service is reachable, a command works in this project — with quick throwaway probes. Probes run in a copy of the project outside the repository, so tools that trust folders (mise) may need `mise trust` first. The `probe` tool takes `command` (a string for `/bin/sh -c`) and `files` (optional scratch files to write first). Kogen runs it in a scratch copy of the working tree under the system temporary folder, never in the project: every file including ignored ones such as installed dependencies and builds, without `.git/` and `.kogen/local/`, cloned copy-on-write where the file system supports it, so a probe can compile and run the project as it is; each probe is stopped after 5 minutes (SIGTERM, then SIGKILL after 5 seconds) and its result is `exit status`, `timed_out` and the combined output (at most 16 KiB, as LOOP-8). The scratch copy is deleted after the probe; nothing of it is kept in the project. The shaper records each probe in the Intent's `## Feasibility` section (SHP-5). Probes are only for genuinely uncertain assumptions the Intent depends on, not a ritual for ordinary implementation knowledge; most Intents need none and record `- none`. A failed probe is a finding, not an error: the shaper reshapes around it or, when it is a UI/UX matter, asks (SHP-6). Probe state does not change the Intent's lifecycle, so no Quint model is needed; the scenarios check that the project is untouched.

Scenarios: `features/02-shaping.feature`. Model: `quint/shaping.qnt` (`NoApprovalWhileAsking`).
