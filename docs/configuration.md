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
- **Models** and efforts live only here; no command takes model flags. Defaults are Sol 6.1 high for shaping/review and Sol 6.1 medium for building. Any nonempty `model` is accepted for every provider and sent unchanged; `effort` is checked against the route's known list when the file is read (see [Open model selection](#open-model-selection)). There is no separate planner; an older `models.plan` entry is ignored.

Init detects Go at the root or under `cli/`; other layouts can be supplied from the README. It deduplicates identical check commands; different commands remain because test paths and filters can change coverage. Machine bootstrap (`mix local.hex`, `mix local.rebar`) belongs in prerequisites rather than recurring setup.

Progress goes to stderr: each build/review request names its model/effort, and completed shape/build/review responses report usage and wall time. Probe completion reports exit status, timeout and duration without echoing its output. A quiet in-flight request has no streaming activity indicator; each logical provider response has a fixed 30-minute absolute monotonic budget, starting before credentials and shared by refresh, lock waits, retries and backoff. Bytes do not renew it. Expiry cancels the HTTP request and reports `provider/unavailable: <ChatGPT|SuperGrok> response wait exceeded 30 minutes` (exit 4); explicit cancellation keeps its signal exit. This is distinct from unlimited project command durations and adds no public timeout setting or retries. Build request durations are also stored as `wall_ms` in the existing run log.

A terminal `response.completed` with omitted output or `output: []` supplies final metadata, not a new empty result: Kogen retains complete streamed done items and any unfinished added items. Success still requires nonempty validated items at contiguous nonnegative indexes, no pending items, and no stream, envelope, status, error or usage failure. Deltas and partial tool arguments cannot authorize tools; function arguments must decode to a JSON object. Nonempty final output instead replaces the streamed output under the existing coverage and validation rules. Rejected responses retain unknown usage; bounded structural diagnostics describe retained state without exposing payloads and are not proof of compatibility success.

`kogen intent refine <slug> <full-sha256> <file|->` corrects an existing ready package. It uses the shaping model and existing commands in a scratch checkout, merges proposals for existing owned files, and requires normal approval afterward. Within the same run, well-formed proposals survive lint/readiness rejection: a retry may submit only corrections, omitted paths retain prior proposed bytes, and explicit original content reverts a proposal. An unsafe or malformed submission contributes no paths. The complete accumulated candidate must pass readiness before any publication; proposals do not resume across separate invocations. It cannot edit configured protection, config, other Intents or shared/tracked step files, add/delete files, change Acceptance paths or add/remove a model. Original and candidate artifacts plus failure diagnostics remain in `.kogen/local/refinements/`; a changed checkout/hash/HEAD/index/approval refuses publication. For an approved package, the full hash must match its approval and ordinary implementation edits must first be preserved and stashed outside the operation. A successful correction archives and revokes the old approval; the caller must explicitly approve the resulting hash. Failures retain original artifacts and approval.

Successful readiness with ordinary baseline failures returns their actual bounded observations to the same shaping/refinement conversation. The model repairs demonstrated fixture defects. After inspecting legitimate missing-feature red, submit the smallest eligible owned artifact with its exact current candidate whole body, including previously proposed corrections. The files array must be nonempty; if only one eligible large artifact exists, submit its entire body. Omitted well-formed proposals remain retained: do not retransmit large unchanged prose/helpers or restore original disk bytes for acknowledgment. Publication and acknowledgment still concern the exact complete package. Exact unchanged full-baseline/HEAD acknowledgment reuses the check. Approval cards show the same checked diagnostics and exit status, including cache hits. Acknowledgment cannot guarantee every later fixture is sound.

### Optional request audit

`shape_audit: {enabled: true}` (default off; `enabled` must be a Boolean, other keys are refused) adds, once per `kogen intent shape` that reaches the model conversation, one fresh read-only call on the shape route that sees only the request text. It lists examples, rules and their cells and reports defects: `conflict` (two statements, different results for one input), `precedence` (no stated winner) and `undefined` (a missing name). The answer is recorded as one `request_audit` event, given to the shaper as lower-authority data, and its tokens or round count join the usage line. An answer that is not a valid `submit_audit` payload stops Shape with `shape/audit_invalid`.

With defects, every questions or files submission is checked by exact substrings before anything is written: a defect is covered by a `## Decisions` line holding its `exposing_input` and not both its results, or by a question holding both quotes. Otherwise the submission is invalid with `Request audit: N defects are not decided or asked; decide each with its exposing input or ask with both quotes:` and one line per uncovered defect. Blocked reports are not gated. With the key absent Shape is unchanged.

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
the main shaper alone runs probes, serially. Worker failure is not retried.
Workers cannot write, submit, approve or publish. A complete common brief and exact
disjoint draft ownership are required before dispatch. Drift invalidates drafts.

Native Shape's generated dynamic block is exactly `Context navigation: ` followed
by single-line JSON and a newline. It has exactly `root` (resolved checkout root),
`revision` (exactly `head` and candidate `tree`, including nonignored changes but
excluding `.kogen/local`) and `retrieval` (`read_file exact bytes and line ranges; list_files directories; search_text exact signatures`).
It contains no repository inventory, signatures or source bodies, and its size
varies with root/revision, not repository cardinality. Native tools discover relevant
facts; the descriptor is not inspection or documentation evidence. Initial Shape,
reconstruction after answers and in-process working windows retain this descriptor
alongside complete request, Q&A, README, testing rules, configured commands and
protection/automatic baseline. Literal inventories in caller requests remain exact.
The complete rendered-request guard remains 524288 UTF-8 bytes inclusive with a
131072-token reserve; irreducible authority still stops unsent, not clipped or split.

Refine remains index-first with deterministic full hashes, exact signature ranges,
directory counts and frozen-original retrieval references. Automatic optional
source-body inclusion stays zero. Explicit excerpts have only path/hash/range
headers and at most 80 lines/8192 UTF-8 body bytes. Refinement retains frozen
originals in its evidence directory and cumulative proposals in scratch.
Focused probes resolve named concrete uncertainties, not a manual replay
of the entire acceptance suite immediately before the native readiness gate.

Append-only `.kogen/local/shaping/<slug>/events.ndjson` survives completion. Each documentation tool lookup appends one retained record to documentation.ndjson in that evidence directory. The record is not probe output, not an Intent provenance line, and not scope authority.
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

### Prompt caching

There is no cache setting: no TTL, switch or per-role option. Every model
conversation (shaper, each shape worker, refine, builder, each reviewer, init)
gets one cache identity of at most 64 characters when it starts. It is saved with
the conversation's checkpoint or records and reused for every later request,
including retries, working-context resets and explicit resume; different
conversations never share one. Instructions and tool definitions stay identical
for the whole conversation and history is append-only, so the provider can reuse
the shared prefix. Which model, effort, tools and provider a role uses never
changes because of caching, and full replay, review independence and every safety
check remain mandatory.

| Provider | Request |
| --- | --- |
| ChatGPT | `store:false`, `include:["reasoning.encrypted_content"]`, body `prompt_cache_key` and underscore headers `session_id` and `conversation_id`, each equal to the cache identity. No private-backend `session-id` header. The headers remain when the body key is stripped or suppressed; a header refusal is an ordinary provider refusal with no new retry or fallback. Never `prompt_cache_options` or `prompt_cache_breakpoint`. Only a definite HTTP400 naming param exactly prompt_cache_key permits one retry with that key removed; unknown_parameter/unsupported_parameter qualify, and ChatGPT alone also accepts invalid_parameter with message exactly "prompt_cache_key is not supported on this model". The original deadline and complete replay remain; refusal stays with that conversation. |
| SuperGrok | body `prompt_cache_key` = the cache identity; one bounded retry without that key after a definite refusal (below). |
| OpenCode Go | header `x-opencode-session` = the cache identity on every request. |
| Anthropic | `cache_control` ephemeral (five minutes) on the last tool, the last system block and the newest message's last block; at most four. |
| OpenAI-compatible | no vendor field or header, because strict hosts refuse unknown fields. The frozen front and append-only history still let a host with prefix caching reuse the prefix. |

Usage keeps each provider's raw cache fields and `kogen intent usage` reports the
cached share from them (see [retained usage](usage.md)). Retained write-12h
counts remain reportable; no 12h setting, prewarm or paid baseline/benchmark call
is introduced. The GPT-5.6+ model split and the explicit cache-options fallback of
earlier Kogen versions are gone; the exact body-key compatibility retry above remains.

## Declared shaping evidence

Shape owns discovery and settlement of material technical questions. Shape finds and retrieves current authoritative documentation for material external facts. Declared shaping evidence is optional and selected by shaping judgment, not a universal registry or coverage claim. Before expensive implementation, identify genuinely uncertain outcome-critical dependencies. Probe the actual proposed request on its supported target route, authentication scope and model, or use a real relevant local fixture; a working old driver or exclusion-list silence does not prove a changed request. Distinguish observed support, explicit rejection and untested uncertainty. Unsupported requests need an honest supported outcome/fallback or clarification of a material UX choice. No blanket paid probes or endpoint sweep.

In `## Feasibility`, add one single-line JSON bullet per explicit obligation, for example:
`- evidence: {"id":"route","kind":"capability","inputs":["route.json","route.cjs"],"observers":[],"checks":[{"name":"support","command":"node route.cjs","exit":23,"output":"explicit rejection\n"}]}`
Ids are unique. Paths name exact repository-relative regular files, including local executable fixtures. A capability has one `support` check. An observer names the final generated protected observer file(s) in `observers` and has exactly two checks in order, `good` and `bad`: those same observer bytes must accept the known-good fixture and reject the known-bad fixture. Every check declares a shell command, expected integer exit and exact combined output string. Nonzero expected exit is legitimate observed rejection; timeout never discharges an obligation. These are small targeted controls, not product implementation or a second acceptance suite. Scratch overlays can explore, but final proof identifies submitted final formatted input/observer bytes. Fresh actual evidence can qualify only identical commands, bytes and outcomes. Narrative, fabricated records, model-only green and missing-feature red cannot qualify a declaration. Readiness executes outstanding checks and retains actual mismatches. Exact red acknowledgment cannot waive an unsatisfied obligation; ordinary no-obligation work needs no probes.

Preserve the complete original request, settled scope and supplied reproducing examples and counterexamples in executable acceptance, not only prose. Do not narrow whole-UI requests to one section or substitute an unconsumed prior-candidate pointer. Advice, proposals and host observations are lower-authority evidence, not product authority. Qualify risky protected observers using actual known-good and known-bad controls even when an earlier missing-feature failure masks them; baseline need not pass the unimplemented feature. Ground fixture/history actors in actual seed output; observe Search before resetting it; compare rendered HTML to rendered expectations, not raw Markdown; account for computed OKLCH rather than assuming RGB; distinguish compiler/process diagnostics from rendered payload; compare JSON objects semantically while preserving meaningful array and string order. A broken fixture is not legitimate product red.

Historical (before prompt caching, KOGEN-054; not current behaviour): keep supplied historical evidence truthful: the changed installed cache request rejected `prompt_cache_options` in 17 seconds with HTTP 400, type `invalid_request_error`, code `invalid_parameter`, message "prompt_cache_options is not supported on this model", although old-driver Shape/Build calls succeeded; current Kogen sends no `prompt_cache_options` (see [Prompt caching](#prompt-caching)). Its historical parameter field is UNKNOWN; omission in a local synthetic control is not evidence of historical absence. The paused f463 record retains completed84/failed0/unknown_usage0 plus one unknown failed request: separate `data.coverage.summary_unknown_requests` and `data.coverage.unrepresented_unknown_requests` are both 1. Arithmetic-only totals miss that uncertainty when coverage is omitted or zeroed; do not fabricate a retained failed or unknown-usage row. The completed legacy correction owns its eight installed-CLI cases; local readiness controls qualify the observer, not that product again.

Native shell/read_file tools remain text-only; explicit view_image alone delivers bounded typed PNG pixels. DOM/action/data/contrast/overflow predicates, screenshot paths and exports do not establish actual pixel interpretation or visual approval. Distinguish successful selection, completed delivery, explicit fallible observations and required human/designer decisions. Retain a truthful external pixel-review handoff when native input is unavailable or refused. The Studio 45-image review found duplicate account shells, excessive mobile headers, raw metadata and weak history hierarchy despite 17 predicates; failed candidates did not reach formal independent review. Studio wholeUI b925 is now completed with root actual 45-image/canonical proof; historical visualhold descriptions are not current status. Cache042 remains OPEN: 20.624% and 0.9168% from different sessions prove neither benefit, quota effects nor miss causes. These historical controls do not authorize account probing; unchanged provider transport keeps its existing f91 qualification. Do not resume paused Go/014 work or duplicate completed Studio/legacy corrections.

## Providers

`models.shape`, `models.build`, `models.review` and each `shape_workers.read`,
`probe`, `draft` selection accept optional `provider: chatgpt`, `provider: supergrok`, `provider: opencode-go`,
`provider: anthropic` or `provider: openai-compatible`.
Omission preserves the exact legacy `{model, effort}` map and defaults; explicit
`chatgpt` routes identically. No template migration is required. An unknown provider
is a configuration error. A role that names a provider needs a nonempty `model` and
`effort`. A provider edit changes the protected approval baseline and prevents
old Build resume. Obtain fresh exact approval.

Model and effort are open: see [Open model selection](#open-model-selection) below for
what is sent, what a refusal looks like and the recommended models.

After installed qualification, the recommended subscription roles are:

```yaml
models:
  shape: {provider: supergrok, model: grok-4.7, effort: high}
  build: {provider: supergrok, model: grok-4.7, effort: medium}
  review: {provider: supergrok, model: grok-4.7, effort: high}
shape_workers:
  enabled: false
```

This repository retains its existing ChatGPT bootstrap configuration. Automatic command discovery with bare `kogen init`
still requires ChatGPT; configuration-first bootstrap below does not. Shape checks its role and enabled workers, Refine checks
Shape, and Build/resume checks Build and Review; unused providers need no login.

`kogen provider login supergrok` uses Kogen's own device-code authorization with
`referrer=kogen` and `User-Agent: kogen/<version id>`. Follow the HTTPS address and
printed user code; no listener or browser is started. Polling follows the returned
lifetime and interval (RFC default 5 seconds, minimum 1 second), adding 5 seconds
on `slow_down`. Cancellation preserves signal exits. A rejected request never
tries another identity. The grant must include `api:access` (absent scope means
requested scope) and usable access/refresh tokens. Failures preserve earlier bytes.
Credentials live only in `~/.kogen/credentials/supergrok.json` (0600), within 0700
credentials and Kogen directories, atomically replaced under `supergrok.lock`.
Refresh occurs 60 seconds before expiry and once after a 401, under the lock with
re-read; omitted rotation keeps the refresh token. Status checks are offline.
Uninstall preserves and names all five providers' credential and lock files.

SuperGrok uses streamed `https://api.x.ai/v1/responses` with full stateless encrypted
replay, typed image outputs, reasoning effort, tools, `stream:true`, `store:false`
and plain instructions. It sends no ChatGPT cache controls, `session-id` header or developer policy,
conversation header, cookies, harness identity or API key. A 402 billing/credit
refusal or 403 access denial stops without retry/fallback; 401 refreshes once then
retries once. Network/429/5xx/cut streams retain the 3-attempt 2s/8s policy. No
subscription-pool exhaustion code is guessed. Unsupported capabilities fail
honestly without dropping fields, changing effort or model, or switching routes.
The 30-minute logical deadline, full rendered 524288-byte inclusive request ceiling,
131072-token reserve, image guards and independent reviewer remain unchanged.

### Installed qualification handoff

Local fakes prove wiring and replay, not account capability, image interpretation,
subscription pool charging or visual approval. After human consent and Kogen-owned
login, run the smallest own-transport check in a throwaway repository: a short
tool-using Shape with `provider: supergrok`, `model: grok-4.7`, `effort: low`,
workers off. Record every actual request outcome, response IDs and nullable usage,
and human-observed grok.com Settings → Usage before/after and Extra Usage (expected
$0, not established by token rows). Unobserved account/UI facts remain UNKNOWN.
Qualify the changed installed Shape/Build/fresh Review at high/medium/high before
using these roles for the second provider Intent. Low-only external harness
evidence does not qualify them. Tools, images, efforts and replay must stop honestly
if refused; when native images are refused retain external preparation/pixel review.
No automatic login, live probe, release/global installation or automatic provider Build
or account charging claim is authorized by this handoff.


### OpenCode Go and role presets

Select `provider: opencode-go` explicitly. The recommended setting is `model: kimi-k3`
with `effort: high` or `default`. `default` omits `reasoning_effort`; any other effort
sends that string unchanged. Effective effort remains null unless actually reported:
accepted high is not evidence of stronger reasoning. Any other nonempty model is sent
unchanged too; Kogen has qualified only `kimi-k3` with retained tools/reasoning
evidence. If Go refuses the model, the refusal line above applies.
GPT stays on ChatGPT, Grok on SuperGrok, Claude uses the independently selected Anthropic API-key connection below.
The [upstream catalogue](https://opencode.ai/docs/go/) is discovery only. Free promotions
are not unlimited: time, region, availability and rate restrictions apply. None is
a default or fallback. ChatGPT can build again (steering-13 supersedes its temporary
conservation window); there is no account-credit toggle.

Complete version-1 starting templates (not verified project checks):
- [OpenCode Go only](presets/opencode-go-only.yaml): Kimi/high for all roles.
- [SuperGrok only](presets/supergrok-only.yaml): Grok high/medium/high.
- [Three subscriptions](presets/three-subscriptions.yaml): ChatGPT GPT-6.1-sol/high,
  Go Kimi/high, SuperGrok Grok/high.
- [SuperGrok and Go](presets/supergrok-opencode-go.yaml): Grok/high, Kimi/high, Grok/high.

These are explicit starting tradeoffs, not benchmark winners or a fallback policy.
Workers remain disabled. No preset is automatically applied to this repository.
For **configuration-first** bootstrap without ChatGPT, prepare your real
`.kogen/project.yaml` from a preset, replace empty setup/fix/check/protect lists and
null acceptance run/steps_dir with your own reviewed project commands and acceptance,
then use the existing `kogen init` leftover-configuration commit path. Commit your
application first. Bare init discovery still requires ChatGPT. No preset command,
init provider selector or automatic router is added.

`kogen provider login opencode-go` accepts only your personal workspace key on stdin
(piped input supported; interactive input is not echoed). Do not put keys in argv,
environment, operator files or another harness. Kogen stores only provider and api_key
in `~/.kogen/credentials/opencode-go.json`, atomically under `opencode-go.lock`, with
0600 file and 0700 custody directories. Empty, invalid, interrupted or failed saves
leave the prior credential unchanged. Login performs no network calls; `opencode-go:
key saved (not verified)` is local presence only. Offline provider list shows absent,
locally usable or saved-login-unusable guidance. Selected roles alone require their
logins; missing Go credentials exit 4 and name the login command. Uninstall keeps and
names all five providers' credential/lock paths.

Go sends Kogen Bearer auth only to
`https://opencode.ai/inference/go/openai/v1/chat/completions`, never pay-as-you-go
`/inference/openai/` or legacy Zen. The loopback-only test seam retains that Go path.
Kogen sends its own `User-Agent: kogen/<version id>` and the conversation's nonsecret cache
identity as `x-opencode-session`, not another harness's identity. JSON is non-streaming, store
false, ordered messages with system policy first, ordered nested function tools and
auto tool choice. No Responses include/input controls, body cache fields, previous_response_id,
truncation, sampling knobs or guessed max_completion_tokens are sent. Complete raw
assistant `reasoning` and `reasoning_details` (including unknown fields and order)
are retained in private `opencode_go_message` replay, alongside normalized tool calls.
Replay sends the raw message once and actual tool outputs in order. No raw reasoning
is analytical telemetry. Images are unqualified: stop before inference with
`provider/unsupported_capability`, exit 4, and external preparation/pixel-review
handoff, never substituted text or a delivered-pixels claim. Other providers retain
native image custody. Full rendered requests, including escaped raw reasoning,
retain the inclusive 524288-byte ceiling and 131072-token local output/reasoning
reserve, not a vendor output-token setting. Fresh owners/windows get distinct
cache identities; append-only turns, retries, window resets and saved-owner resume keep theirs.

401 rejects the Go key without OAuth refresh; 402/403 are honest access/billing
refusals, not fallback permission. Model/capability refusals do not retry. The
30-minute logical deadline includes credential/network/retry waits and cancellation;
network/429/5xx alone use bounded 3-attempt 2s/8s retries. Malformed, truncated,
refused or incomplete completions never execute a partial tool batch.

SuperGrok Responses sends body `prompt_cache_key`, not a redundant
Chat Completions header. Its value is the conversation's cache identity.
API docs recommend it; subscription acceptance and cache benefit remain unqualified.
Only synchronous HTTP 400 with code unknown_parameter or unsupported_parameter and
param exactly prompt_cache_key permits one retry removing just that field. The
refusal survives the owner's checkpoint; later turns do not retry it. Other 400s,
402/403s and failed streams never permit stripping. Rejected attempts retain unknown
usage. ChatGPT retains only the exact body `prompt_cache_key` compatibility retry
described in [Prompt caching](#prompt-caching); both underscore affinity headers
remain on every attempt, including when that key is suppressed. It never sends
`prompt_cache_options` or `prompt_cache_breakpoint`, and its policy/tools/effort and
full stateless replay are unchanged. There is no cross-conversation persistent
refusal registry or component diagnostics.

### OpenCode Go installed security handoff

This package never accesses a live provider or private key. Separate installed
qualification requires an explicit human handoff: supply your key only through
`kogen provider login opencode-go` stdin, confirm the intended single-member Go/Go
Plus workspace, confirm **Extra usage OFF and auto-recharge OFF**, and consent to
minimal own-transport calls. Refuse live qualification without those facts; never
read operator key storage or mutate account settings. Record actual installed
model/effort/routes, tool/reasoning replay, outcomes and nullable usage. Separately
retain human-observed Console usage/credits before/after. Route/key alone cannot
prove subscription eligibility or charging. Go and Go Plus limits differ; exact
remaining allowances are account facts, not rounded percentages.

The external 22 October observation was three kimi-k3/requested-high HTTP 200 calls
with tools/reasoning replay: aggregate input 902, cached 192, output 179, reasoning
90. Credits $0.00 and Extra usage/auto-recharge OFF were observed before/after;
rounded weekly 0% and monthly 11% did not measure consumption. This did not qualify
Kogen, other efforts/models/images or effective strength. Grok cached tokens do not
qualify its cache routing key. SuperGrok's observed
`403 personal-team-blocked:spending-limit` is exhaustion, not route-switch permission.
Cache042 stays OPEN: 20.624% and 0.9168% from different sessions and same-prefix
hit/miss examples prove neither benefit, quota effects nor miss causes. Historical
KOGEN-042 param remains UNKNOWN; synthetic absence is not historical evidence.
API acceptance, cache hits, account savings and visual interpretation are separate
facts. No universal cache guarantee, paid benchmark, endpoint/settings sweep,
savings claim, release/global installation or billing change follows.


### Anthropic Claude API-key roles

Select `provider: anthropic` explicitly in any role or enabled Shape worker.
The recommended models are `claude-opus-5-5` and `claude-sonnet-5-5`, with `low`,
`medium`, `high` or `max`. `xhigh`, which upstream also documents, is accepted too;
any other effort is rejected when the file is read. Any nonempty model is sent unchanged. These documentation-backed
choices do not establish live account/model access. A refusal by Anthropic gets the
refusal line above; no model, effort, provider or account is silently changed.
Omission keeps legacy ChatGPT defaults/maps. A role edit changes approval/checkpoint
identity and cannot authorize old Resume. Refine uses Shape; workers follow their
own explicit selections. Credentials are required only for invoked roles.

```yaml
models:
  shape: {provider: anthropic, model: claude-opus-5-5, effort: high}
  build: {provider: opencode-go, model: kimi-k3, effort: high}
  review: {provider: supergrok, model: grok-4.7, effort: high}
```

Claude may independently occupy Build or Review too. Review always starts its own
conversation with approved authority, actual candidate/source and checks, not builder
reasoning. A blocked Review needs explicit same-checkout Resume and fresh verification.

Run `kogen provider login anthropic` with private stdin or the echo-suppressed
terminal secret flow. There is no key argument or environment-variable authentication;
Kogen does not borrow Claude CLI, browser, subscription or external-agent stores.
This is API billing, not Claude Max or any consumer subscription. Credentials are
atomically saved at `~/.kogen/credentials/anthropic.json` (0600), under 0700 Kogen
and credentials directories with `anthropic.lock`. Invalid/interrupted input keeps
the old bytes. Offline `provider list` shows the saved logins without inference;
`anthropic: key saved (not verified)` distinguishes saving from verified access.
Missing or unusable credentials name the login command and stop with exit 4.
Uninstall preserves both the credential and lock paths.

The native route POSTs Messages to `https://api.anthropic.com/v1/messages`, with
`anthropic-version: 2026-10-21`, adaptive thinking, configured output effort,
streaming and 128000 max tokens. Client tool schemas and ordered raw assistant
blocks (including opaque thinking/signatures and redacted thinking) survive replay,
working windows and v3 checkpoints. Parallel tool results share the immediately
following user message. Cache controls are the ephemeral `cache_control` breakpoints
of [Prompt caching](#prompt-caching) (last tool, last system block, newest message's
last block; at most four). No proxy, Claude subprocess, sampling controls,
beta headers or server tools are used. Complete validation precedes any tool effect.
Only useful complete end-turn text or a valid tool-use batch succeeds; truncation,
refusal and other non-success stops never expose partial tools or alter requests.

Network failures, cut streams, 429 and 5xx (including 529) retain the three-attempt
2s/8s transient policy within one 30-minute logical deadline. Cancellation closes
the socket. Keys do not refresh. 401 is login, 404 model_unavailable, 413
context_too_long, definite 400/402/403 refused; malformed complete output is
invalid_response. Diagnostics retain bounded structural status/type/request IDs,
not arbitrary upstream bodies/messages. All provider failures exit 4.

Total input is input + cache-read + cache-creation only when all three reported
counts are nonnegative integers; otherwise it stays unknown. Cache read and write
remain separately reported, output is reported output, reasoning and 30m/12h write
lifetimes stay null. Cumulative stream snapshots merge/replace, never sum. No hit,
TTL, quota, savings or billing inference follows. Nullable aggregates survive safe
v3 Resume without weakening staged or source/custody checks.

The complete rendered Messages JSON, including system/tools/replay/envelopes, keeps
the inclusive 524288-byte ceiling and 131072-token reserve. Claude typed images
refuse before inference with an external preparation/pixel-review handoff; no
pixels are dropped or replaced with paths/text and no interpretation is claimed.
Other providers' image routes are unchanged.

Deterministic qualification uses synthetic keys and local fake servers only.
Human-supplied-key installed qualification is separate later work: explicit consent,
private login, and exact selected model/effort/tool/replay/Review outcomes must be
recorded. Failure stops honestly, not by fallback. No real key or paid sweep is
part of this feature; Linux deterministic and release real-use qualification remain
separate, unclaimed obligations.

### Open model selection

No provider has a list of allowed models: any nonempty `model` is accepted and sent
unchanged. Known models are only recommended defaults and hints. Efforts are checked
when `.kogen/project.yaml` is read, for every `models` role and `shape_workers` role,
by exact case-sensitive match: `provider: anthropic` and `executor: claude-code`
accept `low`, `medium`, `high`, `xhigh`, `max`; `provider: supergrok` accepts `low`,
`medium`, `high`, `xhigh`. ChatGPT, OpenCode Go and OpenAI-compatible have no known
list, so any nonempty effort is passed through, except `ultra`, which is rejected on
every route. A bad effort fails as `environment/project_config_invalid` with
`line N: models.build.effort "ultra" is not supported; accepted: ...`. The one
exception to sending the effort is `default` on OpenCode Go and OpenAI-compatible: it
sends no `reasoning_effort`.

Kogen cannot know what an account or host offers. If a provider refuses the model or
the request, the error keeps its first line, such as
`provider/model_unavailable: <model> is not available to this <Label> account`, and
adds one line:

```
model <model> with effort <effort> was sent to <Label> unchanged and not retried; if <Label> does not offer them, set another model or effort for this role in .kogen/project.yaml
```

The request is never retried and no other model is tried. Change `model` or `effort`
for that role in `.kogen/project.yaml`. An OpenAI-compatible host's own error text is
shown too, as one line `OpenAI-compatible said: …` (control characters removed, at
most 300 bytes, a saved key redacted), because a local server's message, such as
Ollama's "try pulling it first", is often the fix. ChatGPT and SuperGrok already put
their message in the first line; OpenCode Go and Anthropic bodies are never shown.

The remaining official-family-settings outcome of KOGEN-057 is documented in
[qualified model-family profiles](model-family-qualification.md). Official scope is
Sol Shape/high, Build/medium, Review/high and Sonnet Review/medium, exact normal
routes and text/tool input only. `kogen provider list` appends these scopes after
the unchanged offline login lines; `--json` publishes schema version 1 with exact
limits/settings and separate row-level evidence citations. Neither form checks an
account or refreshes credentials. All other strings remain experimental, may fail
and are not blocked. Newly recorded attempts include selection `compatibility`;
old records without it stay unknown. Contextual refusal diagnostics additionally
name the actual role/provider/model/effort, supported/experimental status and editable
`models.<role>.model` / `models.<role>.effort` selectors in `.kogen/project.yaml`.

Recommended model per role and provider (a starting point, not a requirement):

| Provider | Shape | Build | Review |
| --- | --- | --- | --- |
| ChatGPT | `gpt-6.1-sol` high | `gpt-6.1-sol` medium | `gpt-6.1-sol` high |
| SuperGrok | `grok-4.7` high | `grok-4.7` medium | `grok-4.7` high |
| OpenCode Go | `kimi-k3` high | `kimi-k3` high | `kimi-k3` high |
| Anthropic | `claude-opus-5-5` high | `claude-opus-5-5` high | `claude-opus-5-5` high |
| OpenAI-compatible | the model your host serves | the same | the same |

Efforts the provider's own documentation lists: SuperGrok `low`, `medium`, `high`,
`xhigh`; Sonnet 5.5 `low`, `medium`, `high`, `xhigh`, `max`; OpenCode Go `high` or `default`.
Shape workers (below) use `gpt-6-luna` as an experimental setting. A model or effort
outside these still reaches the provider unchanged.

### OpenAI-compatible hosts

`provider: openai-compatible` serves local and self-hosted models through any
host that speaks the OpenAI Chat Completions API: Ollama, LM Studio, vLLM and others.
Each role that uses it needs `base_url`, an `http://` or `https://` address with a
host and no query, ending before `/chat/completions`. A trailing slash is trimmed.
`base_url` is refused on any other provider. Quote it in a flow mapping.

```yaml
models:
  shape: {provider: openai-compatible, model: 'qwen3-coder:30b', effort: default, base_url: 'http://localhost:11434/v1'}
  build: {provider: openai-compatible, model: 'qwen3-coder:30b', effort: default, base_url: 'http://localhost:11434/v1'}
  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}
```

Usual addresses: Ollama `http://localhost:11434/v1`, LM Studio
`http://localhost:1234/v1`, vLLM `http://localhost:8000/v1`.

- **Request.** A non-streaming Chat Completions POST to `<base_url>/chat/completions`,
  the same wire as OpenCode Go. The model is sent unchanged. Effort `default` sends no
  `reasoning_effort`; any other effort is sent as `reasoning_effort`.
- **Key.** A key is optional. `kogen provider login openai-compatible` reads one from
  stdin (not echoed on a terminal) and saves it at
  `~/.kogen/credentials/openai-compatible.json` (0600); it prints
  `openai-compatible: key saved (not verified)`. With a saved key Kogen sends
  `Authorization: Bearer <key>`. Without one it sends no Authorization header, and a
  keyless local host needs no login.
- **Provider list.** `kogen provider list` shows `openai-compatible: key saved (not
  verified)` once a key is saved. Without a key the list is unchanged.
- **Caching.** No vendor cache field or header is sent (see [Prompt caching](#prompt-caching)).
  Usage reads `prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens` or
  `cached_tokens` when the host reports one.
- **Images.** Unsupported, like OpenCode Go: Kogen stops before inference with
  `provider/unsupported_capability` and the external pixel-review handoff.
- **Refusals.** A host that refuses the model or request gets the refusal line from
  [Open model selection](#open-model-selection). There is no retry.

The unknown-provider message, `kogen help`, the Zsh completion and the uninstall
message all name `openai-compatible`. Roles that omit `provider` stay on ChatGPT.

## Role executors

Each of `models.shape` (Shape and Refine), `models.build` and `models.review` may independently name who runs the role:

```yaml
models:
  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: high}
  review: {executor: claude-code, model: claude-sonnet-5-5, effort: high}
  build: {executor: claude-code, model: claude-sonnet-5-5, effort: high, max_rounds: 6}
```

- **`executor`** is `native` (the default; Kogen's own builder with the provider settings above, byte for byte as before) or `claude-code`. Any other name is a configuration error. A role that omits `executor` stays native; no role takes another role\'s executor, shares a session with it or falls back to the native path. Written out, `executor: native` reads exactly like leaving the key out.
- **`claude-code`** runs your installed Claude Code CLI headless as that role (Build as a textual claim; Shape and Review through schema-constrained structured output). `provider` and `base_url` are refused with it; `model` and `effort` are required; the effort must be `low`, `medium`, `high`, `xhigh` or `max` and is passed to Claude Code unchanged (`--model`, and `--effort` where the installed version supports it).
- **`max_rounds`** (a positive integer, `claude-code` only) caps how many rounds Kogen gives that role's session. The default is 6 per role. A Build that reaches the cap without a verified, reviewed candidate stops with `candidate/executor_round_limit`; the candidate stays in the checkout. The Build also stops the same way, after recording `executor_no_progress`, when three consecutive verification passes fail identically over an unchanged candidate tree; any change or a green pass resets the count.

**Delivery status.** The configuration, the v2 contract, the adapter's structured Shape/Review protocol and the independent **Review** role are in place. Review by Claude Code starts a fresh session (never the builder's), receives the complete exact authority, source and diff as Kogen-owned prompt data (retained privately under the run's `executor-review/` with hashes; a bound of 16 MiB, overflow is `candidate/context_budget_exceeded`), may repair within the Intent, and its verdict goes through the same validation and exact-tree verification as the native reviewer. Red verification returns to the same reviewer; an unresolved blocker stops `candidate/review_blocked`; `intent resume` of an external review checkpoint is `candidate/resume_refused` (start a fresh Build from a Build-clean checkout under the current approval). **Shape and Refine** with Claude Code start a fresh read-only session; its final structured result is the existing `submit` / `submit_refinement` payload, routed through the same validation, readiness, red acknowledgment and publication, and Kogen's feedback returns to the same session. Kogen compares the checkout (tracked, tracked-ignored and nonignored files, modes), the raw index and HEAD around every round: a change stops with `candidate/baseline_changed` or `candidate/head_moved` before publication and is left as it is. Questions keep their numbered CLI; the next invocation is a new session (there is no persistent Claude resume). Enabled `shape_workers` with a Claude Code shaper are refused (`executor/unavailable`) before inference; Kogen's probe, typed images and documentation records are not provided, and research through Claude's own tools is harness-observed only. This is source capability, not live qualification.

**Prerequisites.** Claude Code 2.1.295 or later, installed and signed in with your Claude subscription (`claude auth login`). Kogen never uses an API key, an API base URL or `--bare` for it, strips those variables from the child's environment, and refuses a run whose reported sign-in is not the subscription (`executor/auth_refused`). It does not read, copy or store Claude Code's own tokens; the only token Kogen holds is the one you save yourself (below). A missing binary or an older version stops the Build with `executor/unavailable`. An external role needs no Kogen provider login. Claude Code's usage and cost figures are what Claude Code reports and its own API-equivalent estimate, not a bill; the commit summary prints them on an `executor:` line.

**Stored token.** To skip the interactive `claude auth login`, make a long-lived subscription token with `claude setup-token` and save it with `kogen provider login claude-code`, which reads one token from stdin (or an echo-suppressed terminal), trims it, refuses empty input or a token with whitespace or control characters, makes no network call and never prints it. It is saved privately in `~/.kogen/credentials/claude-code.json` (0600, directory 0700), a second login replaces it, and `kogen provider list` shows `claude-code: token saved (not verified)`. With a token saved, Kogen gives every Claude Code child that needs it (`claude auth status --json`, the first round and every `--resume` round) the token on a fresh inherited pipe at fd 3, written exactly, with `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3` in its env, and it takes precedence over a stored `claude auth login`. Kogen never sets `CLAUDE_CODE_OAUTH_TOKEN` or `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` (with Claude Code 2.1.310 that pair reports permission mode `default`). It replaces the token with `[redacted]` in run records and messages (round streams, stderr, events, error text); it is never in argv or the env. Inherited `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` and `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` are removed and ignored, so only the saved token counts. `claude auth status` does not check a token against the server, so an expired or revoked token is only found in the first round: when Claude Code reports `authentication_failed` or a 401 result, the run stops with `executor/auth_refused` and tells you to run `claude setup-token` and `kogen provider login claude-code` again. Remove it with `rm -f ~/.kogen/credentials/claude-code.json ~/.kogen/credentials/claude-code.lock`.

**What Kogen still owns.** The approved Intent and protected baseline, the fixers, every verification pass and stage gate, independent review (native, or the executor `models.review` selects), the single verified commit, the checkpoints and recovery. A builder's finish is a claim: a red result goes back to the same Claude Code session as feedback, and only a green, reviewed, still identical tree is committed.

**Prevention, detection and verification are separate.**
- *Prevention* is best effort and belongs to the executor: for Claude Code, a PreToolUse hook (this program's hidden `__kogen_executor_hook` subcommand) denies Write, Edit, MultiEdit and NotebookEdit of protected paths, `.git` and anything outside the checkout. Shell commands are not prevented.
- *Detection* is Kogen's, whatever the executor does: after every round the approved baseline must be unchanged and HEAD must not have moved (`candidate/baseline_changed`, `candidate/head_moved`).
- *Verification* is Kogen's exact-tree verification, review and commit. Neither the hook nor a worktree or permission mode counts as process isolation.

**Resume.** A Build run by Claude Code cannot be resumed (its resume capability is none): `kogen intent resume` refuses its checkpoint with `candidate/resume_refused`. Inspect the preserved candidate, or start a fresh Build. The native builder's resume is unchanged, and so are its checkpoints.
