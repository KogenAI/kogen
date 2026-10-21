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
(`intent/run_not_found`). Invalid required local records return 3
(`environment/local_data_invalid`); context instead safely reports invalid.

## Zsh

Save `kogen completion zsh > /some/directory/_kogen`, add that directory to your
Zsh `fpath`, then run `autoload -Uz compinit; compinit`. Regenerate after updates.
No plugin manager or startup-file modification is required. The standalone
definition supports commands, options, files/directories and checkout-local
positionals. Its native private `kogen __complete OP [--project DIR]` helper emits
at most 100 stable tab-separated value/description candidates, without starting
the core, Node, providers or services. OP is build, approve, refine, preflight,
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
same version 1 facts envelope with `kind:"usage"`; it requires neither installed
core nor credentials. See [the scoped usage contract](usage.md) for exact
filters/grouping, limits, nullable measurements, deduplication and provenance.
It observes one canonical checkout, never an account or authorization to resume.
