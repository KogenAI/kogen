# Using Kogen

## Getting started
For a step-by-step guide from install to your first landed feature, see [docs/getting-started.md](getting-started.md). Kogen is one Go program. You need Git, a supported subscription (bare `kogen init` discovery requires ChatGPT; see [configuration-first bootstrap](configuration.md#opencode-go-and-role-presets)), and to build it Go 1.27 and Node 24 (for Quint and Cucumber); no Erlang or Elixir. The toolchain is in `.tool-versions`, for example with [mise](https://mise.jdx.dev): `mise install` (it also lists Elixir for the Elixir fixture project and the Tiny Tasks example, which are projects Kogen builds, not part of Kogen).

To build it from source, start from a plain clone and install the toolchain from `.tool-versions` (`mise install` above):

```sh
git clone https://github.com/KogenAI/kogen
cd kogen
mise install                                   # Go and Node from .tool-versions
sh packaging/package.sh                        # builds dist/kogen-<version>-<platform>.tar.gz
tar -xzf dist/kogen-*.tar.gz -C /tmp
sh /tmp/kogen-*/install.sh                     # installs into ~/.local; needs no administrator rights
export PATH="$HOME/.local/bin:$PATH"           # if install.sh says ~/.local/bin is not on your PATH
kogen provider login chatgpt                   # signs in through your browser
```

Then, in a Git repository of your own with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):

```sh
kogen init                                     # finds and checks the project's commands, commits .kogen/project.yaml
kogen intent shape my-feature ../request.md    # the request, kept outside the repository; answer questions on stdin: printf '1: a\n' | kogen intent shape my-feature -
kogen intent approve my-feature                # shows the card; approve with the hash it prints
kogen intent build my-feature                  # builds, verifies, reviews and commits
```

To correct an existing **ready** package without regenerating it, take the full SHA-256 from `kogen intent approve <slug>` and run `kogen intent refine <slug> <sha256> ../correction.md`. It changes existing owned files only, checks the merged package in scratch and preserves the original on refusal/failure. Within a run, retries retain earlier well-formed proposals and may submit only corrections for edits; publication requires the complete accumulated package to be ready. New/deleted files, shared step edits, changed acceptance paths and model addition/removal need a new shaping request. For an approved package with a stopped protected blocker, use `intent recover` below to preserve and clear its implementation first; only the normal Build-clean paths are allowed. Only a matching approved-current marker imposes these Build-clean restrictions. A nonmatching marker is unrelated stale authority, including historical receipt-less legacy approval; it does not block correction of the ready unapproved current package. A successful correction archives and revokes that approval; failure retains it. Refinement never approves; review and approve its resulting package normally. Refinement audit evidence stays under `.kogen/local/refinements/`. Successful stable shaping, published refinement and card checks supply readiness evidence under `.kogen/local/readiness/`; unchanged cards and hash approval reuse it only for the same complete protected baseline hash, HEAD and Snapshot candidate tree. Missing or invalid evidence runs normal readiness. This does not reuse Build verification or review. Refinement also uses a valid complete version3 record for its exact original-ready precondition, including projects with nonempty setup. A hit skips only the fresh original setup/model/acceptance execution; it is retained evidence, not proof of current environment readiness. Missing, malformed, stale or invalid evidence follows the normal mutation-guarded original scratch check. Every changed complete candidate runs fresh configured setup and normal readiness, even after a hit; environment drift can fail it. After inspecting legitimate missing-feature red, submit the smallest eligible owned artifact with its exact current candidate whole body, including previously proposed corrections. The files array must be nonempty; if only one eligible large artifact exists, submit its entire body. Omitted well-formed proposals remain retained: do not retransmit large unchanged prose/helpers or restore original disk bytes for acknowledgment. Publication and acknowledgment still concern the exact complete package. Exact unchanged acknowledgment does not repeat that gate. Raw index checks remain operation safety; exact candidate tree identity also controls reuse.

Within a shaping conversation, corrective file submissions retain earlier well-formed proposals; omitted paths are kept. Previously declared proposed JavaScript steps and a proposed model must stay declared. To discard an earlier new artifact, preserve and park the partial package and its exclusively owned new step files, remove the empty Intent directory, then shape again with the same slug or a new one. Failed shaping does not provide a cross-invocation proposal resume.

For a generated project, commit the runnable scaffold first; `kogen init` then makes a separate `Add Kogen configuration` commit. A truly empty Git worktree can instead start with a configuration-only `Initial commit`; uncommitted application files must be committed before initialization. An uncommitted request belongs outside the repository.

`kogen init` keeps only the checks that pass on your committed tree, and sets up acceptance with the Cucumber Kogen ships, or with the project's own; [docs/configuration.md](configuration.md) explains `.kogen/project.yaml`. Dependency manifests and lockfiles (such as `mix.exs`, `package.json`, `go.mod` and their lockfiles) are editable inputs when they only describe project/dependency metadata. Dedicated formatter, linter and suppression settings remain protected. A combined manifest that defines a configured check, such as an npm check script or a Mix check alias, may be protected whole-file; it then has no dependency-only edit exception. If shaping reports a genuine conflict, revise the request, or review and commit `.kogen/project.yaml` outside Build and shape again. This manual review changes the approval baseline; it is not approval to edit a protected file in Build. Preserve checks and their actual configuration. `kogen init` ends with readiness lines (install, Git, configuration, model logins) with the exact fix under each failure, and a command that cannot proceed names what is missing and how to fix it in its error. `kogen help` lists every command, and `kogen uninstall` removes the program.

## Checkout facts and completion
Use `kogen context` for JSON checkout activity and last-started Build facts,
`kogen intent list`, `kogen intent inspect <run-id>` and
`kogen intent preflight <slug>` for discovery and read-only investigation.
The latter three accept `--json`; all four accept `--project <checkout>`.
Context and completion are local reads that need no login, provider or network. See
[the version 1 contract and standalone Zsh installation](checkout-facts.md).
Preflight is not authorization: Build still performs its normal safety checks.

## Prompt reuse and retained usage
`kogen intent usage [RUN-ID] [--lineage] [--project DIR] [--json]` explains
local retained transport evidence without credentials or inference. It reports
weighted cache ratios, nullable writes/lifetimes, unknown/inconsistent counts,
failures and provenance; totals cover selected evidence, not just displayed rows.
This is not account or weekly usage. Every model conversation has one cache identity (at most 64 characters, kept across retries, resets and resume, never shared with another conversation). ChatGPT sends it as body `prompt_cache_key` and underscore headers `session_id` and `conversation_id`, SuperGrok as `prompt_cache_key` (with one bounded refusal retry), OpenCode Go as `x-opencode-session`, and Anthropic marks ephemeral `cache_control` breakpoints on the last tool, last system block and newest message (at most four); OpenAI-compatible hosts get no vendor field or header (a host with prefix caching still benefits from the frozen front and append-only history). Kogen keeps full stateless encrypted replay, independent reviewers and fresh safety/verification gates, and the usage report shows the cached share from each provider's raw cache fields. Cache acceptance is
not proof of a hit, effective lifetime or live account qualification. See
[usage scope, filters and uncertainty](usage.md).

## Approval step limits and refusal diagnostics
`kogen intent approve <slug>` bounds each command it executes during a fresh readiness
check (each setup command, each model check step and the acceptance command) by its own
120 seconds. The bound is per step, never shared and not a setting: there is no retry, option
or environment knob, and individually timely steps may take longer than 120 seconds overall.
A step over its bound is stopped with its process group and refused as `environment/step_timeout`,
naming that step, its elapsed wall time, the steps that ran before it with their wall times
and statuses, and the steps never reached. Elapsed time alone cannot tell host contention from a
hang, so Kogen names no cause. The Git phases (`snapshot`, `materialize`) are timed and recorded but not
separately bounded.

Every refusal after a command ran shows that command's own combined stdout and stderr (the
Excerpt line policy within the 16384-byte display bound) and retains it, up to 1 MiB, in private local
evidence: `.kogen/local/readiness/attempts/<slug>-<time>-<id>/attempt.json` (0700/0600), with each
executed step's name, kind, status, exit, `timed_out`, start and duration in milliseconds, and
`not_run` names. The path is printed. It is diagnostic custody only: not readiness evidence
(`<slug>.json` is unchanged and never written for a refusal), not approval, and never reused.
Interrupts keep their signal exit codes and retain nothing.

Secrets are masked before any excerpt or byte bound is applied: the values of nonempty environment
variables whose names contain TOKEN, KEY, PASSWORD or SECRET, the string
fields named like a secret in Kogen's own `~/.kogen/credentials/*.json`, Authorization header
values and `Bearer` values, and values assigned to names containing token, key, secret, password or
passwd (`name=value`, `name: value`, `--name value`). An unlabeled secret Kogen was never given
cannot be detected. A secret straddling the command runner's own 512 KiB head/tail capture of one
command's output, or a command line the caller asks the runner to trace with `KOGEN_LOG_LEVEL=debug`, is outside this masking.

## Recovering stale approval cards
`kogen intent approve <slug>` checks current readiness and prints the full lowercase
64-character SHA-256 and an approval command containing that full hash (exit 5).
It never approves or starts Build. Existing 6–64-character hash prefixes remain
supported. A wrong prefix names the full current hash and the usable card command.
A nonmatching marker is labelled **Stale approval**, with its full old hash: it
cannot authorize the current package or Build.

An intact receipt with an older contract binding is historical diagnostic source,
not custody corruption or current readiness proof. The card shows both full contract
hashes and explicitly states that Shape has not run again, alongside actual readiness,
source comparison/path/hash/binding, protected files and the complete ordered staged
plan. Intrinsic invalid content still reports its parse/lint cause. Cards change
neither approval nor successful source history. After ordinary readiness, explicit
current-hash approval can refresh the receipt binding while preserving exact request,
Q&A, origin and corrections. The prior receipt is retained byte-for-byte in native
hash-named history, linked with prior/current contract identities; this is not another
Shape. Superseded marker bytes are privately archived and the inspectable path printed.

After fresh same-slug Shape, a stale marker's displaced current.json reference resolves
only through its exact pinned digest in safe native receipt history. A matching approval
still requires its exact current custody. Missing, changed or unsafe receipts refuse:
restore the named exact receipt from preserved history before running the card; if it
cannot be restored, stop. Fresh approval is not a cure for broken custody. Genuine
receipt-less legacy packages remain supported.

`kogen intent refine <slug> <full-current-sha256> <correction-file>` can correct a ready
unapproved current package despite stale authority, without Build-clean restrictions
solely from that marker. Normal ownership/shared-file limits, original readiness,
authentication, scratch checks and full-hash requirements remain. Refine freezes marker
bytes and current/resolved pinned custody; only success archives/revokes the marker.
Failure/cancellation preserves package, successful source, approval, HEAD and index,
and rollback never overwrites concurrent external edits. Refine never approves.
Matching approved-current Refine retains normal clean-path and explicit protected-blocker
recovery requirements. No approval transfer, automatic continuation or old Build proof
is imported: approve the corrected full current hash and start a fresh verified,
independently reviewed Build. Read-only `context` / `intent inspect` remain the
observation route, not an automatic scheduler or polling loop.

Approval records the exact Git HEAD used for readiness. A fresh Build refuses an
older or missing base even when package bytes are unchanged. After moving an intact
unchanged package, run `kogen intent approve <slug>` to inspect fresh readiness and
both bases, then explicitly approve the printed hash. The card alone never approves.
If the moved scenarios already pass, correct the obsolete contract with Refine;
changed or conflicted packages require ordinary Refine or Shape, not approval transfer.
Restore exact unsafe source custody before running the card; if restoration is
impossible, stop. No previous Build verification or review is reused.
