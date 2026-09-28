# Proving runs: live-shaping-quality on the fix3 prototype (2026-09-26)

These runs follow lesson 18 and the Shaper's instruction: "run `make
live-shaping-quality` once on the fix3 branch with changes 1 and 2 applied
(in a clone, not this checkout), and fold anything it breaks into the
contract."

## Setup

- Disposable clone:
  `/private/tmp/claude-501/…/scratchpad/fix3`, branch `proving` from
  `backup/shaping-preflight-audit-fix3` (61be8365). `deps/` and `_build/`
  were rsynced from the main checkout; `mix.lock` is unchanged between them.
- Probe commit fbfd13a8, changes 1 and 2 (`prototype-changes-1-2.diff`,
  first part):
  - the auditor runs once per HEAD; a second run only after findings;
  - 180 s limit;
  - after the bound is used up, the hook allows with "auditor bound
    reached";
  - a 10-minute reshape-chain budget, with the auditor skipped when less
    than 30 s is left and its limit capped at what remains;
  - `elapsed` fields in `hook.jsonl`.
- Focused tests on the prototype: 33/35 passed. The 2 failures are the
  revision-11 rules that revision 12 deliberately changes: "the hook has no
  elapsed-time or turn-count threshold" and "a changed revision after a
  clean confirming run stays not ready".
- No Build was running, and there was no `.kogen/build.lock`. A Shaping
  session for another package was idle. The load average was about 3.

## Run 1: 05:17:47Z to 05:25:37Z, failed (exit 2), 469 s

- `booking-complete` failed on `case_succeeded`:
  `correlation.all_owned_terminal == false`. The other six cases were
  cancelled by the suite when it failed.
- Its hook log had one stop: `outcome: environment`, `audit_ms: 185677`,
  `launch_elapsed_ms: 244531`.
- Its auditor record: `status: unavailable`, `reason: "auditor time limit
  (180 s)"`, `run: 1`, `gpt-6-luna` low.
- Cause: revision 11's `auditor.md` still says "Your working budget is 8
  minutes", so the fast auditor worked past the 180 s kill. The killed
  auditor root has no `task_complete`, and the driver's terminal
  correlation and `integrity.py` both reject that.
- Folded into the contract: a 2-minute brief (`blind-auditor-layer`), and
  the evaluation accepts a Kogen-killed auditor
  (`evaluation-answers-front-loaded-questions`). See `questions.md` R12-2.
- Limitation: the raw run-1 directory was deleted in the clone before
  run 2, by mistake. The facts above were read from it before deletion.
  Only this summary remains.

## Run 2: started 05:27:55Z

- Probe commit 29919f5c (second part of the diff): the 2-minute brief, plus
  the driver and `integrity.py` accepting an auditor killed at its time
  limit.
- Result: failed (exit 2) after 593 s (05:27:55Z to 05:37:48Z). The suite
  failed on `booking-complete`, with "captured evidence integrity failed: at
  most 2 auditor root sessions are allowed". The other six cases were
  cancelled after their first asking stops. Those stops were allowed as
  `asked`, the question gate took 0.9 to 1.2 s, and they came 96 to 314 s
  after launch.
- `booking-complete` (568 s) asked nothing. Its only stop came 375 s after
  launch. The audit took 184 s, and the auditor was killed at 180 s even
  under the 2-minute brief. `owned-session-metadata.json` shows one Shaper
  root, plus four `gpt-6-luna` sessions tagged auditor from one run:
  the auditor root, which completed, and three sub-agents with no
  completion.
- Cause: Codex 0.156.1 has the `multi_agent` feature enabled by default
  (`codex features list`: `multi_agent stable true`). The auditor's
  `codex exec` has no `agents.*` config but can still `spawn_agent`. It fanned
  out, waited on the sub-agents, and ran into the kill.
- Folded into the contract: the Codex auditor launches with
  `--disable multi_agent` (`auditor-setting`). The flag is accepted by the
  managed runtime (`codex exec --disable multi_agent --help`, exit 0).
- Budget observation: a case that asks nothing spends about 375 s before
  its first stop, so a 180 s auditor plus one reshape does not fit a 600 s
  case by construction. Run 3 measures the auditor without sub-agents.

## Run 3: 05:40:31Z to 05:49:20Z, failed (exit 2), 529 s

- Probe commit adds `--disable multi_agent` to the Codex auditor argv.
- The suite failed on `csv-flawed` (496 s): "captured evidence integrity
  failed: owned native session has no completion". The other six cases were
  cancelled.
- In `csv-flawed`, the asking stop came at 98.7 s and took 1.1 s in the gate.
  The final stop's audit took 184 s, and the auditor was killed at 180 s.
  It had one auditor session and no sub-agents, so the `multi_agent` fix
  held.
- The auditor's timeline: the prompt arrived at 7 s. A JSON preamble message
  came at 24 s. Tool calls followed at 31, 58, 74 and 118 s (find/cat of the
  package, evidence, `rg`), and then the kill came. Each step took about 25 s,
  so a tool-exploring auditor cannot finish a scoped read in 180 s.
- `integrity.py` has a second completion check, in its loop over owned
  sessions. The run-2 patch covered only the auditor-specific check and the
  receipt.
- Folded into the contract: the auditor prompt inlines the package and the
  scoped files, bounded, and asks for one reply with no commands
  (`blind-auditor-layer`). The evaluation accepts a Kogen-killed auditor at
  every completion check.

## Run 4: 05:51:35Z to 05:51:57Z, failed after 22 s (environment)

- Probe commit: inline, one-pass auditor prompt (the package plus scoped
  files, 24 KB per file, 160 KB total), and `integrity.py` accepting a
  Kogen-killed auditor at every completion check.
- Every Codex launch refused with "shaping and expert harness codex is not
  ready: unexpected discovery settings in Kogen credential store:
  …/codex/accounts/shared/plugins".
- `plugins/` was created at 05:47:15Z, during run 3's `csv-flawed` auditor
  session (started 05:46:05Z). Its rollout alone carried a
  `<recommended_plugins>` context. The same case's Shaper root, launched with
  Kogen's prepared `--disable apps --disable plugins --disable
  shell_snapshot`, did not. The other Shaping session's Codex probe ran at
  05:58Z, after the directory already existed. The Shaper removed the
  directory.
- Folded into the contract: the Codex auditor argv carries the three
  lesson-10 disables itself (`auditor-setting`). The flags are accepted by the
  runtime.

## Run 5: 06:00:15Z to 06:10:42Z, failed (exit 2), 627 s; `plugins/` not recreated

- Probe commit adds `--disable apps --disable plugins --disable
  shell_snapshot` to the auditor argv. After the run the shared scope had no
  `plugins/`.
- `stateful-complete` failed at 605 s with "native startup turn": its first
  turn never ended. `csv-continuation` failed at 618 s with "malformed or
  uncorrelated native event for submitted turn", the transport flake also
  seen in Build SQyTuy3C cycle 1. The rest were cancelled. No auditor ran in
  any case, so the inline brief was not exercised.
- Asking stops came at 177 to 301 s after launch, with gate audits of 0.9 to
  2.4 s. In `csv-complete` and `stateful-flawed`, the hook blocked once
  (chain 81 s and 96 s) and then allowed the next asking stop.
- `stateful-complete` timeline (24 tool calls over 581 s): it read the
  README and sources for 45 s and wrote the Draft at 134 s. It ran `mix
  kogen.audit eval-stateful-complete` itself at 141 s, then edited and re-read
  its own audit reports until 572 s, never ending its turn.
- Folded into the contract: inside a Shaping session, `mix kogen.audit`
  audits nothing and prints the latest status with "end your turn to
  re-audit". `shaping.md` says not to run it (`revision-report-and-command`).

## Run 6: the revision-12 flow

Probe commits add:
- the flow prompt: helpers research while the root asks within the first 5
  minutes, and answered entries leave `## Ask the Shaper`;
- `--search` for the Codex Shaper;
- the in-session audit that only prints status;
- a later round of questions counts as asking again;
- the driver answers later asking stops within its 6-reply bound.

Result: 06:12:43Z to 06:23:08Z, failed (exit 2), 625 s. `plugins/` was not
recreated.

- `stateful-flawed` and `stateful-complete` failed with "native startup
  turn" at 604 s. Both roots followed the new flow: in `stateful-complete`
  the root spawned `source_reader` and `evidence_reader` helpers (luna low)
  at 84 s and 100 s, then asked through `request_user_input_async` at 132 s
  ("Failure output: Show concise failure plus remediation (Recommended)").
  The driver cannot answer a native panel, so the root waited, did its own
  reading from 384 s, and was still writing its Draft at 579 s. The root
  also read the README and sources itself for about 80 s before spawning
  helpers.
- `csv-flawed` failed at 605 s: "initial request turn did not save Draft and
  settle its Stop hook". `csv-complete` (604 s) and `csv-continuation`
  (618 s) hit the "malformed or uncorrelated native event for submitted
  turn" transport failure.
- The inline one-pass auditor worked. `booking-flawed` got run 1 `ok` with
  4 findings, then run 2 (confirming) `ok` with 1. `booking-complete` got
  run 1 `ok` with 2. The audits that included them took 49 s and 100 s, and
  45 s, all inside the 180 s limit. The hook blocked on them as designed
  (chains of 192 s and 62 s).
- Every case's `owned-session-metadata.json` listed the same six auditor
  sessions. Auditors run in materializations, not fixtures, so the driver's
  correlation attributes every auditor to every case.
- Folded into the contract:
  - Codex keeps its native `request_user_input` (`## Assumed` 1 corrected);
  - the driver answers native panels with the recommended option;
  - auditor sessions are attributed only through the case's own auditor
    records (`evaluation-answers-front-loaded-questions`, `front-loaded-questions`).

## Where the proof stands

Six runs, about 60 minutes of paid evaluation, and no passing run yet.
Proven and folded in:
- option B;
- the once-per-HEAD auditor with the 180 s kill;
- the inline one-pass brief (finishes in about 45-100 s);
- `--disable multi_agent` plus the lesson-10 disables (no `plugins/`);
- the killed-auditor acceptance;
- the question gate at about 1 s per stop;
- the Codex root following the helper-and-ask flow.

Not yet proven:
- the driver answering Codex question panels;
- per-case auditor attribution;
- whether every case then fits 600 s;
- the recurring "malformed or uncorrelated native event" transport failure,
  which appeared in runs 5 and 6 and in Build SQyTuy3C. It is a driver
  correlation defect, not a provider outage, and still needs a root cause.

The Draft is not ready (lesson 18). The next step is prototyping the
driver's panel answering and auditor attribution in the clone, then run 7.

2026-09-26: prototype-changes-1-2.diff removed on the Shaper's direction 26 (no reused implementation). The runs above remain as lessons only.
