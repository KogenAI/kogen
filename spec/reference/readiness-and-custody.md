# Readiness, continuity and evidence

## Clean final readiness
Final readiness uses a fresh disposable directory materialized from `Snapshot.tree`, with exact tracked (including ignored tracked) bytes, executable modes, additions/deletions and synthetic local Git. It runs verbatim declared setup before model/acceptance; ignored untracked dependency/build outputs are neither copied nor linked. Caller environment, installed tools and declared services remain available: this is not hermeticity. Raw scratch mutations, including staged additions, reject proof. Source identity is rechecked around execution and publication, including approval. Disposable directories are removed on success, failure and interruption. Exploratory probes remain warm.

Readiness record version 3 adds `candidate_tree` to the complete baseline/hash, HEAD, declarations and actual model/scenario/exit evidence. Only exact unchanged clean evidence is reusable; version 2 and older are normal misses, never migrated. Ignored untracked warmth does not affect identity; nonignored changes, deletions, executable modes, tracked ignored changes, HEAD, protected baseline and declarations do. Retaining original-precondition evidence skips only original setup/model/acceptance, not fresh changed-candidate proof, and is not current-environment proof. Refine tests and publishes its complete accumulated formatted proposals; Shape tests its final formatted files. Accounted red remains inspectable and exact unchanged acknowledgment reuses the same clean observation. Evidence also retains actual final-attempt skipped Gherkin steps, including Backgrounds and expanded Outline rows; cards and Shape/Refine feedback summarize their count before failure details and list their source locations. Skipped steps are unexercised: readiness proves neither their behavior nor fixture validity. Version 3 records missing valid skipped-step metadata are ordinary misses, not silently empty observations. Build verification, review and explicit caller approval remain separate.

## Private working continuity and source provenance
All native model-facing text tool results (Shape, Refine, Build and independent Review), including errors and control feedback, share a 16384
UTF-8 byte bound **including** the omission marker. Fitting text is unchanged.
Oversized displays preserve the first 4096 bytes and a suffix, backing off incomplete
characters, with `\n[... N bytes omitted ...]\n` counting actual original bytes absent.
Conservative marker reservation may leave a few bytes unused. The display is
idempotent and retained exactly with its tool call for replay, not recut on resets.
Line ranges do not bound bytes: explicitly selected ignored custody remains readable,
but large reads are visibly incomplete. Private originals, archives, structured
documentation records, native probe evidence, complete authority and required complete
pinned Review source delivery are unchanged. Typed images pass unchanged under their
existing limits. This does not make arbitrary authority, arguments or batches fit.

Build and its independent reviewer preflight the **complete rendered next JSON request**
against a fixed **524288 UTF-8 byte** ceiling (equality fits), with **131072 tokens**
reserved for output/reasoning. This is a conservative byte proxy, not observed usage,
a provider rejection threshold or a total-Build limit. No provider/model/effort or
stateless transport capability changes. Completed safe boundaries can start an explicitly
labelled local working window; authority and current unfinished work/findings remain,
while full ordered replay is retained privately under
`.kogen/local/runs/<id>/working-context/<owner>/` with SHA-256 links. Opaque reasoning,
assistant phase and complete tool batches are preserved. Irreducible requests stop as
`candidate/context_budget_exceeded` before inference, naming retained custody and ordinary
Refine/new-approval guidance. Native provider context errors below the proxy remain honest failures; a Claude Code "Prompt is too long" refusal is a context result.

Version 3 checkpoints retain the active owner/window, archives, findings and source binding;
version 2 and older are explicitly unsupported, inspectable and refused without changes.
Resume requires the user's index to record exactly the saved staging. A plain `git status` that
only refreshed entries' stat cache (timestamps, inode, size) after the stop is not a change and is
reported; any staged path, mode, object, stage, flag or extension change (including Git's
cache-tree, so even restaging identical content refuses), a version 4 or split index, or a
damaged index still refuses. Fail closed means setups whose `git status`
also rewrites an extension (untracked cache, fsmonitor) or that write index version 4 or a zero
checksum (`feature.manyFiles`, `index.skipHash`) still refuse after a status. `kogen intent recover`
keeps exact index byte equality.
Missing, altered or unsafe bound custody is a refusal, not a new Build. Editing makes old
green evidence stale, and a reviewer reset neither clears blockers nor starts a new critique.

Native Shape supplies `Context navigation: <JSON>` as a single-line dynamic block,
with exactly `root`, `revision` (`head` and `tree`) and `retrieval`. The resolved
checkout root and candidate revision replace the generated repository inventory;
retrieval is `read_file exact bytes and line ranges; list_files directories; search_text exact signatures`.
Descriptor size does not grow with repository cardinality. Shape must still inspect
relevant files and establish documentation evidence through native tools. Exact
request/Q&A, README, testing rules, commands and protection/automatic baseline stay
complete; caller-supplied inventories are not stripped. Refine retains its frozen-original
context index and explicit excerpts. This is not a guarantee that every request fits.

At a completed Review boundary, an oversized next request can relocate the exact
original inline source/diff to the same private ordered source parts and try one
smaller window. Small fitting continuations are unchanged; pinned source is not
re-pinned on every reset. Supported version-3 inline checkpoints use their exact
saved blocks, including explicit resume after a provider failure, without restarting
Review or Build. Older source without an established tree binding is labelled
historical, never reconstructed from an edited checkout. Every newly pinned part
must reach the reviewer through a complete matching read_file output, or a Kogen native
source-data message carrying that exact text, in a completed continuation before approval. Each Review reset handoff carries `review_delivery`: the
pinned-part tree and whether it is current, delivered count and unread part numbers, and
every image this review was given, as of its newest delivery (path, SHA-256, read candidate,
current, pixels still in the next window). A reviewer that could not tell what it already
received rebuilt it in every window; these facts are not findings or
approval. Native current-tree checks alone determine eligibility.

Native Refine also preflights complete rendered requests within one invocation.
At completed response/tool-batch boundaries it archives oversized input under
`.kogen/local/refinements/<attempt-id>/working-context/<n>.json` and tries one
deterministic smaller window. Version-1 archives retain owner `refine`, exact input
and the previous path/hash (null first); new custody directories are 0700, files
0600, and hashes cover complete bytes. Every window keeps exact initial correction,
owned originals, README, testing rules, commands/protection and source-provenance
binding, plus the newest complete exchange, current complete proposal manifest,
ownership, readiness observations/identity, invalid count and assistant observations.
Documentation remains complete in native state and private snapshots, not inline bodies. Cumulative native proposals remain authoritative;
handoffs are diagnostic, not model-authored substitutes or approval. Old manifests
remain in exact history. Linked custody is validated before subsequent inference,
tool effects and publication; missing, altered, symlinked or unsafe custody stops as
`candidate/context_custody_invalid`, preserving package and approval.

Refine emits `working_context_reset` events and progress with measured before/after
bytes and retained custody. A reduced request must be both smaller and within the
unchanged inclusive ceiling. Irreducible input is retained exactly unsent in the
same chain with `working_context_stop`, measured/mandatory bytes and limits; it
stops before inference as `candidate/context_budget_exceeded`. An identical fresh
retry is not recovery: Refine has no persistent resume or automatic retry. Ordinary
scope/correction changes may be needed. Publication, exact red acknowledgment and
new exact approval requirements remain unchanged.

Native Shape can continue across bounded local working windows within one invocation.
At a completed provider/tool boundary it preflights the complete next request, archives
oversized active input privately under
`.kogen/local/shaping/<slug>/working-context/<attempt-id>/` (0700 new directories,
0600 files, SHA-256 links), and tries one deterministic smaller window. It keeps exact
initial authority and request/Q&A, cumulative proposals, discovery/documentation state,
readiness identity, invalid count, assistant observations and the newest complete exchange.
Handoffs and archives confer no approval or discovery authority. Missing, altered or
unsafe linked custody refuses further inference/publication. Irreducible input is retained
exactly unsent with `candidate/context_budget_exceeded`: a fresh identical retry is not
recovery; correct the request/scope or prepare images externally. There is no summarizer,
automatic splitting or persistent Shape resume, and not every large request fits.

Native Shape can retain files in bounded pieces with `propose_files` before one `submit` checks the complete package: a long package is written one long file or a few short ones per reply instead of in one very long reply, and a cut-off reply loses only itself. Proposals are kept privately under `.kogen/local/shaping/<slug>/proposed/` and are named when a provider failure stops Shape. A proposal runs no checks and is not an invalid submission. No reply size limit, option, timeout or retry is added.

Shape and Refine reset handoffs carry only `history: {head: {path, sha256}, count}`
and `documentation: {path, sha256, count, format: "ndjson"}` evidence references.
Each numbered version-1 archive binds its immutable sibling `<n>-documentation.ndjson`
before hashing. Snapshots preserve every native record in order, including duplicate
and failed lookups, one JSON object and final newline per record (empty state is
empty bytes). Follow archive `previous` links for complete ordered replay; retrieve
one-based documentation lines with `read_file` `start_line`/`end_line`. Both owners
validate every bound snapshot alongside linked archives even for fitting continuations,
before inference, tool effects or publication. New custody uses 0700 directories and
exclusive regular non-symlink 0600 files. These references are diagnostic, never new
authority; native history and documentation lists remain complete and unchanged.

Successful Shape keeps exact request/Q&A and source identity privately at
`.kogen/local/provenance/<slug>/current.json` (0600 files, 0700 custody directories).
Successful Refine archives the previous receipt, retains originals and appends the exact
correction/prior contract identity. Failed/refused attempts leave successful custody and
approval unchanged. The shaper's bounded `## Source comparison` and approval card identify
addressed, omitted, conflicting and superseded behaviors/non-secret literals. Native Shape
and Refine require a nonempty report of at most 8192 UTF-8 bytes and return missing or
oversized reports for correction rather than clipping them. This mapping
is an aid, never proof of semantic completeness. Cards show the receipt path/hash and
contract binding; Build and fresh independent review can retrieve originals with native
read tools. Originals are diagnostic data, **not authority** to add omitted scope. Such
changes require ordinary Refine and new exact approval. Legacy projects explicitly report
`Source provenance: unavailable (legacy)`; originals are never reconstructed from Intent prose.
Do not place credentials in these private receipts or handoffs.

For a stopped `candidate/build_blocked` Build, explicitly run:

```sh
kogen intent recover <build-id> --output ../new-private-archive [--project <checkout>]
```

`--output` is required and caller-relative: it must name a NEW directory outside the
resolved checkout, with no symlinked custody. Recovery takes the normal Build lock,
validates a complete version-3 checkpoint, retained BUILDER-REPORTED blocker/result,
checkout/HEAD/index/protected baseline/configuration/approval/candidate and bound
working-context/image/source custody. Missing/legacy checkpoints are
`candidate/recovery_unsupported`; other unsafe facts are `candidate/recovery_refused`
(exit 1). Unsupported arguments (including `--context`) are usage errors (exit 2).
This is a completed native protected stop, not permission to resume uncertain tools.
Other provider, login, resource and interrupt stops keep their ordinary explicit
resume behavior. Ordinary implementation failures still return to the builder.

Before removing any implementation bytes, recovery publishes a private archive
(0700 directories, 0600 regular files) with exact before/candidate data and Git modes,
a hashed `manifest.json`, unchanged approval/index/checkpoint/result, retained blocker,
and bounded `correction.md`/`context.md` handoffs. Symlinks are regular archive data,
not followed. The printed absolute manifest path and SHA-256 identify preservation.
Only the recorded implementation delta is restored to start-tree bytes/modes; recorded
additions are removed. Protected files, other Intents, ignored outputs, HEAD, original
index, approval and prior run evidence stay unchanged. No stash, commit, provider call
or project command runs. Inspect `.kogen/local/recoveries/<build-id>.json` for archive
path/hash and `preserved` or `cleaned`: an incomplete cleanup is NOT success. Never
retry over an archive or guess reconciliation after a partial cleanup.

Run the printed Refine command with the ORIGINAL full contract hash and correction.md.
Refine must independently investigate this builder-reported, unproven claim and pass its
normal readiness gate; successful correction revokes the old approval. Review and freshly
approve the exact corrected package, then start a production-clean FRESH Build with the
generated `--context context.md`. Archived production is lower-authority diagnostic data,
not authority or current proof. Selective tool inspection is allowed, but there is no
automatic stash/patch/tree import, protected-byte replay, approval transfer or reuse of old
green/model/reviewer results. Full normal setup, checks, acceptance/model, independent
review and final changed-tree verification apply; landing consumes the new approval.
Recovery invokes none of these next commands. Read-only `context` and `intent inspect`
are the observation path for long work; no scheduler, polling or automatic retries are added.

## Selected native image evidence
Shape, Build and fresh independent Review share `view_image(path)`, one read-only
selected local image resolved like read_file (repository-relative or explicitly
selected absolute path). Only static non-interlaced 8-bit RGB PNG is supported:
**1..131072 original bytes**, width/height **1..2048**. Unsupported, missing or
expired artifacts need ordinary external preparation/export/capture and reselection.
There is no scanning, capture, transcoding, hosted service, Files API or image generation.
Shell/read_file remain text-only, even when printing paths or base64.

Success freezes exact original bytes as ordered typed Responses content plus metadata.
The read-time repository candidate is recorded when established; capture candidate,
route, viewport and fixture state remain `UNKNOWN` without separately established
provenance. Filenames/hashes/current checkout do not prove the intended candidate was
served. Provider preprocessing may change resolution; no detail guarantee is added.

Successful read, completed pixel delivery, explicit fallible visual observations,
DOM/action/accessibility/layout checks and human/designer decisions are separate.
Name pages, states and viewports actually inspected and retain final candidate-bound
evidence. Fresh Review obtains its own pixels; builder judgments are not inspection.
When provenance is stale/unknown or native input is refused, retain an honest outside
capture/pixel-review handoff. Unrelated work needs no image invocation.

Frozen outputs survive changed/deleted paths in private ordered replay, Build/Review
archives and version-3 checkpoints (0700 directories/0600 files). Missing, altered or
unsafe custody refuses resume before inference/mutation. Complete serialized JSON,
including base64, envelopes, policy, tools, cache controls and replay, retains the
524288-byte inclusive ceiling and 131072-token reserve. Build/Review and Shape keep completed
safe working windows; Shape has no persistent resume. Irreducible requests stop before sending with retained custody and external
image preparation or ordinary Refine/new-approval guidance. Images cannot change
approval, protected contracts, failed/stale/unknown checks, blockers or exact-final-tree
commit eligibility. Local scripted-provider tests establish plumbing/custody, not
actual visual interpretation or automatic design approval.
