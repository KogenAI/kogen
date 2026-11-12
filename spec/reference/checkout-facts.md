# Checkout-local facts (schema version 1)

`kogen context [--json] [--project DIR]` returns JSON by default. `kogen intent
list [--limit 1..100] [--cursor TOKEN]`, `kogen intent inspect RUN-ID` and
`kogen intent preflight SLUG` default to human output; add `--json` for consumers.
All accept `--project DIR`, including a nested directory. Linked worktrees have
separate checkout identities, local records and approvals.

JSON stdout is one UTF-8 object and newline: `schema_version: 1`, `kind`
(`context`, `intents`, `run`, `preflight`), `checkout`, `data`, `error`.
`checkout` is null outside a project, otherwise `{id, root, git_dir}`. Paths are
canonical absolute paths. The opaque ID identifies this exact checkout; do not
parse it. Errors contain `class`, `reason`, `detail`, `paths`. Required nulls mean
unknown, absent or not applicable; empty arrays mean no entries. Progress is stderr.

Context outside a project succeeds with `project: false`, null `active` and
`last_built`, `integration_state: missing`. In a project `project` is true.
`.kogen/local/context.json` is the integration snapshot, atomically replaced as a
whole. `last_built: {slug, run_id}` records the latest accepted start, including
failed starts after custody acquisition; it is not the most recent success or a
Git trailer. `active` has `slug`, `run_id`, `phase`, `verification_pass`. Phases
are startup, building, verifying, reviewing, committing; only verifying has a
positive pass number. Ownership is checked now against the live process birth
and unique lock token. Dirty files do not establish activity. Missing/invalid
snapshots yield missing/invalid integration state and unknown facts, never a
history reconstruction. Readers do not repair snapshots.

Listing separates package/approval rows from individual Build attempts, ordered
by slug, package first, then descending start timestamp and ascending run ID.
Default page size is 20 total rows. Cursors describe an unchanged dataset;
invalid/stale cursors are usage errors. Package validity uses retained static
identity, not freshly executed readiness. Approval identity is compared with
current bytes where its recorded baseline is available; otherwise it is unknown.
Legacy history is not automatically migrated. The bounded evidence summaries
are published by lifecycle owners, separate from opaque checkpoint authority.

Inspection includes lineage, recorded outcome, last phase, actual pass/review
summaries, stopping reason, blockers, custody paths, commit, resume status,
next command and separately labelled observations. At most the latest 20 pass
and review summaries are retained; full evidence remains in the run artifacts.
A dead unfinalized owner is interrupted, not a fabricated completed result.
`potentially_available` is not permission to resume: the normal command performs
all exact approval, custody, protected baseline and checkpoint validation.
`unsupported` offers no retry bypass. A landed attempt retains its full commit;
explicit resume validates its landed no-op rather than building again.

Preflight is a read-only point-in-time investigation. It reuses Config.load!,
Intent.check, Intent.baseline/hash, Build.clean_paths!, Git.operation_in_progress
and Lock's read-only ownership observation. Git observations disable optional
index refresh locks and the configured filesystem-monitor hook. It never acquires/recovers locks or executes configured
commands. Checks are configuration, package, approval, cleanliness, conflict.
`ready` means only those observations passed. Setup/checks/hooks/providers,
tool availability, signing, full readiness and resume safety are not established.
Build always revalidates. Blockers return exit 1 with data and null error;
invalid environment/configuration returns exit 3. Read success is exit 0,
including empty lists; usage is 2 (`intent/invalid_argument`), absent projects
are 3 (`environment/not_project`), unavailable paths are 3
(`environment/project_unavailable`), unknown runs are 1
(`intent/run_not_found`; see below). Invalid required local records return 3
(`environment/local_data_invalid`); context instead safely reports invalid.

`kogen intent inspect <run-id>` for an unknown run says which case it is in
`error.detail` and adds the string `error.next`, always `kogen intent list`
(the command that lists run ids); `reason`, `paths` and the exit code do not
change. An id that is not 8 lowercase hexadecimal characters has detail
`not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d`;
a well-formed id with no record in this checkout has detail
`no run with this id in this checkout`. No other error object has `next`.
When standard output is a terminal, one sentence `<detail>. Next: <next>` is
also written to standard error after the JSON line; if standard output is a
pipe, a file or `/dev/null`, nothing is added, even when standard error is a
terminal.

## Pending shape questions

When `kogen intent shape <slug> <file|->` stops on questions (exit 5), it also
leaves the pending questions and their recommended options in
`.kogen/local/shaping/<slug>/questions.json`, beside `state.json` in the 0700
shaping directory. The file is a regular file with mode 0600, replaced as a whole
(a temporary file in the same directory, then a rename), in the version 1
envelope above: `kind` is `questions`, `checkout` is `{id, root, git_dir}` as
`kogen context` reports it and `error` is null. It is written whether or not a
terminal is attached, before the questions are printed; the printed block and
exit 5 are unchanged. Exit 5 with this file present tells an unattended caller
that shape stopped on questions (`intent/exists` also exits 5, and leaves no such
file).

`data` has exactly `slug` and `questions`: the unanswered questions of the latest
round in ascending number order, the same ones the run prints. Each has `number`
(as printed and as used in `<n>: <answer>` lines), `question`, `kind` (`handoff`
for an authentication or security handoff, otherwise `product`), `options` (in
printed order, each `{letter, label, recommended}`; empty when the question has
none) and `recommended`, the letter of the first recommended option, which is the
one `all: recommended` picks, or null.

The file is written when the shaper submits a new round of questions and when an
answer input leaves questions of the pending round unanswered, so after `2: a`
answers question 2 of two it lists only question 1. It is removed, with
`state.json`, when shaping ends ready (exit 0). Other endings, including refused
answers, leave it, as `state.json` still holds the same pending questions;
deleting `.kogen/local/shaping/<slug>/` discards both.

Answering stays an explicit caller act through the existing input: `all:
recommended` or `<n>: <letter or your words>` lines through
`kogen intent shape <slug> -` (or a file). The answers are recorded with the
Intent as for any other answer, and `kogen intent approve` still refuses pending
questions.

## Zsh

Save `kogen completion zsh > /some/directory/_kogen`, add that directory to your
Zsh `fpath`, then run `autoload -Uz compinit; compinit`. Regenerate after updates.
No plugin manager or startup-file modification is required. The standalone
definition supports commands, options, files/directories and checkout-local
positionals. Its native private `kogen __complete OP [--project DIR]` helper emits
at most 100 stable tab-separated value/description candidates, without starting
Node, providers or services. OP is build, approve, refine, preflight,
inspect or resume. Resume candidates exclude known unsupported and landed runs;
a candidate is never a safety guarantee. Static completion works outside projects.
Context and run completion read fixed integration files; run completion never opens
package bodies or the historical run directory. Evidence summaries point to their
original attempt artifacts after resume, not nonexistent files in a new attempt.
Inspection checks checkpoint presence now; checkpoint compatibility and all other
resume safety remain the authoritative resume command's responsibility.
Context and completion use local integration records, not historical log streams.

## Usage investigation

`intent usage [RUN-ID] [--lineage] [--project DIR] [--json]` is a separate,
bounded retained-history scan, not part of context or completion. It uses the
same version 1 facts envelope with `kind:"usage"`; it requires no credentials.
See [the scoped usage contract](usage.md) for exact filters/grouping, limits,
nullable measurements, deduplication and provenance.
It observes one canonical checkout, never an account or authorization to resume.
