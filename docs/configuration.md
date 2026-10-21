# `.kogen/project.yaml`

`kogen init` writes this file and commits it: it finds the project's commands, runs each once on the committed tree and keeps only those that pass, and prints what it left out. Edit the file only where you disagree, then commit it. Every command reads it; an invalid file is refused with its line numbers.

```yaml
version: 1
commands:
  setup:                # run before readiness dry runs and before each Build and each fresh clean candidate verification pass, in order
    - 'mix deps.get'
  fix:                  # deterministic fixers, run once after each builder round
    - 'mix format'
  checks:               # the project's fast regression suite; a Build commits only when all pass
    - {name: format, run: 'mix format --check-formatted'}
    - {name: test, run: 'mix test'}
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: 'features/steps'   # where shaping writes step-definition files
protect: ['.formatter.exs']       # check configuration a Build must not change
models:
  shape:  {model: gpt-6.1-sol, effort: high}
  build:  {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
```

- **Commands** run with `/bin/sh -c` in the repository root, with your environment, stdin closed and no time limit. Kogen adds `KOGEN_NODE` and `KOGEN_CUCUMBER` (its own Node and Cucumber) and, for the acceptance command, `KOGEN_ACCEPTANCE_FEATURES` and `KOGEN_ACCEPTANCE_REPORT`.
- **Checks** are `{name, run}` with unique lowercase names (letters, digits, dashes); `acceptance` and `model` are reserved. A check that already fails on the unchanged tree stops a Build before it starts, so fix it or remove it.
- **Flaky tests.** A Build's repair loop treats a failing check as something to fix. If the project's tests fail now and then, rerun only the failed ones once in the same check, for example `mix test || mix test --failed`, or `npm test || npm test` for a runner without a failed-only mode.
- **Services.** Test databases and other services are the project's own: start them before Kogen, and put what prepares them (for example `mix ecto.create`) in `setup`. A check that needs a stopped service fails in `kogen init` and is left out; add it back once the service runs.
- **Acceptance.** Kogen ships Cucumber 13.3.0 and runs it on its own Node, so the project needs no Node of its own. A project that already has `@cucumber/cucumber` in its `package.json` keeps its own, run as `"$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js ...`. Step files go in `steps_dir` and use `require('@cucumber/cucumber')`.
- **protect** lists paths or globs of actual verification definitions/settings (linter rules, formatter settings, suppression files). They are part of every Intent's approved baseline, so a Build cannot pass a check by weakening them. Dependency manifests and lockfiles are editable inputs when they only declare dependencies/project metadata: for example ordinary `mix.exs`, `package.json`, nested `go.mod`, `mix.lock`, `package-lock.json`, `npm-shrinkwrap.json` and `go.sum` are not protected merely because setup, format, compile, tests, vet, audit or another check consumes them. `cli/go.mod` is an editable input. A combined manifest is eligible when it embeds verification settings (such as eslintConfig) or itself defines a configured executable check, such as a package.json script used by an npm check or a Mix alias invoked by a configured command; that manifest remains whole-file protected. There is no field-level or dependency-only exception to explicit whole-file protection. Init rejects dependency-only protection with a path-specific correction request rather than silently deleting it. Existing committed configuration remains authoritative and is not migrated automatically.
- A genuine shaping conflict means a required edit cannot be avoided without changing the requested outcome and a currently protected path is involved. Shaping reports the protected path and reason without writing a ready Intent or starting approval/Build. Revise the request, or review and commit `.kogen/project.yaml` outside Build, then shape again while preserving checks and actual check configuration. That manual review changes the approval baseline; it is not approval of a protected edit. There is no protected-edit override. If a combined manifest is explicitly protected, revising the request is the available Build path.
- **Models** and efforts live only here; no command takes model flags. Defaults are Sol 6.1 high for shaping/review and Sol 6.1 medium for building. There is no separate planner; an older `models.plan` entry is ignored.

Init detects Go at the root or under `cli/`; other layouts can be supplied from the README. It deduplicates identical check commands; different commands remain because test paths and filters can change coverage. Machine bootstrap (`mix local.hex`, `mix local.rebar`) belongs in prerequisites rather than recurring setup.

Progress goes to stderr: each build/review request names its model/effort, and completed shape/build/review responses report usage and wall time. Probe completion reports exit status, timeout and duration without echoing its output. A quiet in-flight request has no streaming activity indicator; each logical ChatGPT response has a fixed 30-minute absolute monotonic budget, starting before credentials and shared by refresh, lock waits, retries and backoff. Bytes do not renew it. Expiry cancels the HTTP request and reports `provider/unavailable: ChatGPT response wait exceeded 30 minutes` (exit 4); explicit cancellation keeps its signal exit. This is distinct from unlimited project command durations and adds no public timeout setting or retries. Build request durations are also stored as `wall_ms` in the existing run log.

`kogen intent refine <slug> <full-sha256> <file|->` corrects an existing ready package. It uses the shaping model and existing commands in a scratch checkout, merges proposals for existing owned files, and requires normal approval afterward. Within the same run, well-formed proposals survive lint/readiness rejection: a retry may submit only corrections, omitted paths retain prior proposed bytes, and explicit original content reverts a proposal. An unsafe or malformed submission contributes no paths. The complete accumulated candidate must pass readiness before any publication; proposals do not resume across separate invocations. It cannot edit configured protection, config, other Intents or shared/tracked step files, add/delete files, change Acceptance paths or add/remove a model. Original and candidate artifacts plus failure diagnostics remain in `.kogen/local/refinements/`; a changed checkout/hash/HEAD/index/approval refuses publication. For an approved package, the full hash must match its approval and ordinary implementation edits must first be preserved and stashed outside the operation. A successful correction archives and revokes the old approval; the caller must explicitly approve the resulting hash. Failures retain original artifacts and approval.

Successful readiness with ordinary baseline failures returns their actual bounded observations to the same shaping/refinement conversation. The model repairs demonstrated fixture defects. After inspecting legitimate missing-feature red, submit the smallest eligible owned artifact with its exact current candidate whole body, including previously proposed corrections. The files array must be nonempty; if only one eligible large artifact exists, submit its entire body. Omitted well-formed proposals remain retained: do not retransmit large unchanged prose/helpers or restore original disk bytes for acknowledgment. Publication and acknowledgment still concern the exact complete package. Exact unchanged full-baseline/HEAD acknowledgment reuses the check. Approval cards show the same checked diagnostics and exit status, including cache hits. Acknowledgment cannot guarantee every later fixture is sound.

### Optional native Shape workers

Workers are an opt-in trial, not an initialization default. No worker is enabled
when `shape_workers` is absent or `enabled: false`. Supplied roles must always
contain exactly nonempty `model` and `effort` strings; enabling requires all three.
Unknown keys are configuration errors with source line numbers.

```yaml
models:
  shape: {model: gpt-6.1-sol, effort: high}
  build: {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
shape_workers:
  enabled: true
  read: {model: gpt-6-luna, effort: medium}
  probe: {model: gpt-6-luna, effort: medium}
  draft: {model: gpt-6-luna, effort: max}
```

Only native Shape advertises `shape_batch`; refinement, Build and review do not.
The main shaper integrates evidence and submits one merged package through normal
readiness. Sequential work remains valid, especially for small or coupled tasks.
Luna read/probe medium and draft max are experimental settings, not performance
or quality claims. Each conversation has one blocking batch, one to three jobs,
six calls, twelve ordinary tools and two probes per job. Provider HTTP can overlap;
the original bridge owner alone runs probes, serially. Worker failure is not retried.
Workers cannot write, submit, approve or publish. A complete common brief and exact
disjoint draft ownership are required before dispatch. Drift invalidates drafts.

Native context is index-first: deterministic indexes and full hashes, with zero
automatic optional source-body excerpts (including Acceptance steps and licences);
`read_file`, `list_files` and `search_text` retrieve exact source bytes. Request,
Q&A and authoritative contract details are complete, not replaced by a summary.
Root and revision are shared once; ordinary exact paths resolve from root. Frozen
originals and complete signature pages retain explicit retrieval references.
Explicit excerpts have only path/hash/range headers and at most 80 lines/8192
UTF-8 body bytes. This does not bound conversation growth or imply speed/cost savings. Refinement
retains frozen originals in its evidence directory and cumulative proposals in
scratch. Focused probes resolve named concrete uncertainties, not a manual replay
of the entire acceptance suite immediately before the native readiness gate.

Append-only `.kogen/local/shaping/<slug>/events.ndjson` survives completion.
Refinement writes its own events and original-readiness receipt. These are evidence,
not cache, proposal, approval or shared-artifact authority. Supplied input bytes are
not tokens. Usage can be unknown; model/probe phase times are interval unions,
not additive elapsed-time components. No monetary savings are inferred.

Issue attribution: DELIVERY-20261018, “Shaping decomposition follow-up”, external
knowledge workspace `research/benchmarks/proposals/studio-driven-delivery-2026-10-18.md`.
That workspace is not a repository dependency or a new register.

An unexecuted paired validation plan could compare sequential and opt-in arms on
identical frozen requests, baselines and settings: preparation, failures/corrections,
overlap-aware elapsed time, known usage and unknowns, fixture validity and independently
correct contracts. No benchmark, default adoption or speed/quality guarantee follows.

## Clean final readiness

Final readiness uses a fresh disposable directory materialized from `Snapshot.tree`, with exact tracked (including ignored tracked) bytes, executable modes, additions/deletions and synthetic local Git. It runs verbatim declared setup before model/acceptance; ignored untracked dependency/build outputs are neither copied nor linked. Caller environment, installed tools and declared services remain available: this is not hermeticity. Raw scratch mutations, including staged additions, reject proof. Source identity is rechecked around execution and publication, including approval. Disposable directories are removed on success, failure and interruption. Exploratory probes remain warm.

Readiness record version 3 adds `candidate_tree` to the complete baseline/hash, HEAD, declarations and actual model/scenario/exit evidence. Only exact unchanged clean evidence is reusable; version 2 and older are normal misses, never migrated. Ignored untracked warmth does not affect identity; nonignored changes, deletions, executable modes, tracked ignored changes, HEAD, protected baseline and declarations do. Retaining original-precondition evidence skips only original setup/model/acceptance, not fresh changed-candidate proof, and is not current-environment proof. Refine tests and publishes its complete accumulated formatted proposals; Shape tests its final formatted files. Accounted red remains inspectable and exact unchanged acknowledgment reuses the same clean observation. Build verification, review and explicit caller approval remain separate.

## Fresh Build diagnostic data

For a **fresh** Build only, optional operator diagnostic data can be supplied with
`kogen intent build <slug> [--project <checkout>] --context <file>`. The file is
caller-relative (not project-relative), readable and regular, nonblank valid UTF-8,
and at most 262144 original bytes. It is read once and preserved exactly in private
local run custody (0700 directory, 0600 `diagnostic-context.json`), separate from
approval and commits. Do not put credentials in it; this is not a credential store.
The labelled lower-authority message does not replace the approved Intent or native
protection, checks, review or commit rules. Old candidate observations are untrusted
data, not automatic reuse, import or proof. After a demonstrated protected fixture
correction, obtain new exact approval before a fresh Build. `intent resume` accepts
no `--context`: it uses its saved conversation even if the source changes or vanishes.

Deterministic prompt and guard tests do not establish live model obedience or performance. Qualification uses a separately packaged frozen private prefix and scoped installed use outside the checkout; no global install, push or release is implied. Root owns Studio recovery qualification and adoption. Preserve short commit subjects and the exact `Kogen-Intent: <slug>` trailer without an appended hash; native approval hashes stay in their binding fields.
