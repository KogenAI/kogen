# Kogen specification

This specification describes Kogen. Kogen takes a requested feature through five steps:

1. **Shape.** Write the feature as short prose, Gherkin and Quint.
2. **Build.** Implement it with Kogen's own model/tool loop.
3. **Verify.** Run the acceptance scenarios against the real code, check the model and run the project's checks, repairing until they pass.
4. **Review and fix.** An independent reviewer repairs supported defects; changed contents receive external final verification. Unresolved substantive blockers stop with preserved work.
5. **Commit.** Make one commit of exactly the verified and reviewed contents, signed or unsigned as the user's Git configuration says.

Around these sit only the parts needed to use them: setup, ChatGPT and SuperGrok login and status, the CLI, install and `kogen uninstall`. Callers are people at the command line or agents such as ChatGPT driving it.

The specification decides technical details; UI/UX choices are asked of the person requesting a feature (SHP-6). It follows KISS and YAGNI: no speculative defensive branches, fallbacks, compatibility layers or future-proof abstractions.

Out of scope: queues, background runs, daemons, sandboxing, history or archive services, recipe or plugin frameworks, distributed execution, providers beyond ChatGPT and SuperGrok, API-key fallback, account switching, automatic updates, automatic Build recovery, rebasing, merging, pushing, and time or token limits on Builds.

## Structure

```text
spec/
  README.md
  prose/                   one chapter per area; requirements carry ids such as SHP-6
    01-project-setup.md            SET
    02-shaping.md                  SHP
    03-approval-and-build-start.md AUT
    04-building.md                 LOOP
    05-verifying.md                VER
    06-reviewing.md                REV
    07-committing.md               GIT
    08-chatgpt.md                  GPT
    09-cli-and-process.md          CLI
    10-install-and-uninstall.md    INS
    11-release-acceptance.md       REL
  quint/
    shaping.qnt       shaping readiness and who may approve or start a Build
    build.qnt         Build, verify, repair, review and commit eligibility (no limits)
    run_control.qnt   one Build per repository, interruption, exit codes
  features/          one .feature file per chapter, plus STEPS.md (conventions, fixtures,
                     fake ChatGPT scripts, step patterns)
  tools/check.mjs    offline well-formedness check
  check.sh           runs every check
  package.json       pins the check tooling (package-lock.json pins the rest)
```

To read it, start with chapter 09 (the whole command surface). Then follow one Intent through chapters 02 → 03 → 04 → 05 → 06 → 07. Chapter 11 says when the release is done.

## Checking it

```sh
cd spec && npm ci && sh check.sh            # Node 24; npm ci only once
```

`KOGEN_SPEC_NODE_MODULES` can point at an existing `node_modules` instead of running `npm ci`. `check.sh` does the following:

1. Parses every feature with `@cucumber/gherkin` 42.0.1 (scenarios under `Rule:` included; a scenario that compiles to no test case fails).
2. Checks that every scenario has a requirement tag, that every requirement has a scenario, that every requirement id used in prose and this README is defined, and that every Quint name cited in prose is a conjunct of that model's `Safety`.
3. Checks that every step matches exactly one pattern in `features/STEPS.md`, and prints the trace table (requirement → chapter → scenarios → Quint) on request with `node tools/check.mjs --trace`.
4. Runs `quint typecheck` and `quint test` (Quint 0.33.0, TypeScript backend, Node only).
5. Simulates each model against its `Safety` invariant with these recorded seeds:

   | Model | Seed | Samples | Steps |
   | --- | --- | --- | --- |
   | `shaping.qnt` | 7 | 2000 | 20 |
   | `build.qnt` | 11 | 3000 | 60 |
   | `run_control.qnt` | 3 | 3000 | 30 |

6. Runs non-vacuity checks: each deliberately false claim must produce an actual Quint counterexample, and any other failure fails the check.

None of this executes a scenario. Parsing features and matching step patterns only show that the specification is well formed. Behavior is established only by running the scenarios against the real application (REL-4) and by real use on real projects (REL-1).

## Technical choices (made here, not questions)

- **Answers to shaping questions:** one line per answer, `<n>: <answer>` (an option letter or free text). This works the same for a person typing and for an agent writing a file.
- **One Build per repository:** a lock file, created exclusively, holds the Build's pid. A lock whose process is gone is removed with a notice.
- **Acceptance runner and Gherkin:** Kogen ships `@cucumber/cucumber` 13.3.0 next to Quint and runs it, or the project's own Cucumber, on its own Node; `kogen init` writes the command (`commands.acceptance.run`, SET-10, SET-13). Kogen reads the Gherkin it needs with its own Elixir parser (VER-3, VER-4).
- **No time or token limit on Builds or commands.** Every command runs with stdin closed, so a prompt fails at once. The builder starts dev servers and watch modes in the background with output to a log file, reads the log and stops them itself. Ctrl-C stops the Build, and every process group a Build started is terminated when the Build ends. Shaping probes keep their 5-minute bound (SHP-10).
- **Testing rules:** `../docs/testing-rules.md` (outside `spec/`, shipped as `docs/testing-rules.md`) chooses the tests for every change, in Kogen's own code and in every product built with Kogen. The shaper, the builder and the reviewer each get its text (SET-6); the fixed test sequence is VER-13; the adoption steps for an existing project are SET-9; Kogen's own tests are REL-7.
- **Interruption:** SIGINT, SIGTERM or SIGHUP (exit 130, 143, 129) stops the Build without a commit (and stops `shape` and `approve` the same way); so does the death of the `kogen` command, which the core sees as end of its stdin. The active command's process group gets SIGTERM, then SIGKILL after 5 seconds. Kogen makes no claim about processes that left the group.
- **Review/fix:** one fresh conversation to `models.review`, with protected file writes, command execution and `submit_review`. Changed contents are verified externally; failures continue in the same reviewer context. Maintenance-only objections are notes. An unresolved substantive blocker stops rather than restarting the builder. An invalid verdict is sent back once.
- **Install:** to `$HOME/.local` by default. If no Node 22 or newer exists, the current Node LTS is installed into Kogen's own folder; Quint 0.33.0 and Cucumber 13.3.0 ship in the archive.
- **Uninstall:** removes the program and keeps `~/.kogen` (the login) and every project.
- **Supported platforms:** macOS on Apple Silicon and Linux x86-64 with glibc, at the versions release acceptance runs on.
- **Defaults:** model output capped at 16 KiB per tool result; provider retries 3 attempts, waiting 2 s and then 8 s; an interrupt completes within 15 s; init commit message `Add Kogen configuration` (`Initial commit` in a repository without commits).

## Where this lives

This folder is `spec/` of the Kogen repository, next to the supervised Mix app and the Go command under `cli/`.

### Continuation trace

LOOP-10 continuation uses the CLI-1 command and AUT-4 lock. The maintained
`04-building.feature` unknown-checkpoint scenario and installed resume Intent
scenarios exercise the real CLI; `build_boundaries_test.exs` covers pending final
verification and same-reviewer custody, `builder_blocker_test.exs` covers refusal
of protected contradictions, and `run_test.exs` covers decode/publication.
`build.qnt` includes explicit builder/reviewer resume tests without resetting
candidate or green evidence; `run_control.qnt` includes lock reacquisition after
an ended attempt. Existing Safety invariants and non-vacuity counterexamples
continue to cover commit eligibility, independent review and live-owner refusal.


### Protected-blocker recovery trace

LOOP-7/LOOP-10 explicit recovery is covered through the installed command by
`.kogen/intents/build-unblocking-recovery/acceptance.feature` and its independent
archive/lifecycle controls. `test/integration/recovery_test.exs` exercises raw Git
filters, binary/mode/symlink custody and publication before a controlled filesystem
cleanup failure. `quint/recovery.qnt` models archive-before-cleanup, non-reapproval
and fresh final-commit proof (`Preserved`, `NoReapproval`, `SafeCommit`). Its bounded
trace uses seed 11, 100 samples, 30 steps, matching the approved recovery model;
this is bounded evidence rather than exhaustive proof. Observer polarity is enforced
by callable Feasibility validation and actual final-byte installed card controls;
invalid good-nonzero/bad-zero declarations cannot become readiness or reuse evidence.
