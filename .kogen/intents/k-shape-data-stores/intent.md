# Find where an entity's data lives before scoping

Slug: k-shape-data-stores
Model: not applicable — one more mechanical gate in the existing Shape submission path, one more evidence block in the existing review authority and one more rule in the existing verdict validation; no new state or transition
Acceptance:
- .kogen/intents/k-shape-data-stores/acceptance.feature
- features/steps/k_shape_data_stores_steps.js
- features/steps/go_driver_support.js

K-SHAPE-DATA-STORES (Kogen issue 09096a6e, research of 2 Nov 2026). For a request about an entity's data (for example "delete a cancelled account's data"), the shaper scopes only what the entity's model reaches through its associations. Data the repository keeps in other stores keyed by the entity's id (other tables, files, indexes) is silently dropped from scope and acceptance, and review approves with no findings. On a private benchmark task 0 of 8 saved acceptance files and 0 of 3 valid Intents mentioned the two such stores, 6 of 7 landed cells passed review with no findings, and all 7 landed cells failed the same hidden checks; the same frozen Intent with only those stores added landed 4 of 5 requested checks instead of 2 of 5, with 0 regressions. Shaping, not Build, is the binding stage. (Evidence: the model-free step-0 scan codex-helpers/fbp1 and the build-ceiling probe codex-helpers/fbc1o3, e746e82, eu2, 2+2. They are motivation only: no hidden-test or benchmark content is used anywhere in this change.)

After this change an Intent about an entity's data records where that data lives in an optional `## Data stores` section of `intent.md`: the spellings of the entity's id key, and for every file that references a key an item that puts it in scope with acceptance that observes it, or excludes it by a sourced Decision. Kogen finds the files mechanically with a model-free scan of the files tracked in Git (any language or stack; nothing Rails-specific), Shape refuses a candidate whose section leaves a referencing file uncovered, Shape's instructions tell the shaper to establish the stores before writing scope and acceptance, and the Build's independent review receives the same scan as evidence: a file the approved Intent leaves uncovered must be a blocking finding, so review cannot approve it silently. Intents without the section, and every other Shape, approval, Refine and Build behaviour, are unchanged. No new command, flag, option or configuration key; no timeout, limit or retry is added or raised.

## The `## Data stores` section
- Optional. The section is the `- ` lines from the line `## Data stores` up to the next line starting with `#` (the same reading as the other sections, `sectionBullets` in `cli/project/intent.go`); other lines in it are ignored. An `intent.md` without a `## Data stores` line gets no data-store gate and no review evidence. `kogen intent approve` and the SHP-5 lint do not check the section.
- Each `- ` line is exactly one of (backticks literal, `<n>` a decimal integer of at least 1 without leading zeros):
  - `- key `<key>`` — a spelling of the entity's id key, `<key>` nonempty without backtick or whitespace (for example `account_id`, `accountId`, `account.id`); at least one is required;
  - `- `<path>`: in scope, observed by `<text>`` — `<path>` a repository-relative path, `<text>` nonempty without backtick;
  - `- `<path>`: excluded by decision <n>`.
  A `<path>` ending in `/` is a directory and matches every scanned file whose path starts with it; any other `<path>` matches only the file with exactly that path.
- An item is valid when, checked in this order: (1) at least one file tracked at the scanned commit matches its path; (2) for `in scope`, `<text>` occurs in `acceptance.feature` or in a step file listed under `Acceptance:` (their contents on disk); (3) for `excluded`, `## Decisions` has at least `<n>` bullet lines and (4) its `<n>`th bullet line contains `<path>` exactly as written in the item (trailing `/` included). Decisions keep their required `(source: request)` / `(source: answer N)` tag as today.

## The scan (shared by Shape and review)
- Keys are the declared keys in section order, each once. For each key, the references are the files tracked at the scanned commit, outside `.kogen/`, whose content contains the key with no letter, digit or underscore immediately before or after it, binary files skipped — exactly what `git grep -I -n -w -F -e <key> <commit> -- . ':(exclude).kogen'` reports — with the 1-based numbers of the lines that contain it. On the fixture below, `my_account_id` and `account_ids` are not references of `account_id`, and `exports/<account_id>.json` is.
- A reference is (file, key, lines), ordered by file path (byte order), then by key order. It is covered by the first valid item, in section order, whose path matches its file.
- The scanned commit is `HEAD` for Shape (the candidate's own new files are not at HEAD and are not scanned) and the commit the Build started from (`Attempt.Start`) for review. A section without a valid key line produces no references.
- Line numbers are written `(line 1)` for one line and `(lines 1, 4)` for several, joined by `, ` in ascending order.

## Shape: the data-stores gate
- Where: every Shape, native and external (`executor: claude-code`), in `checkSubmission` (`cli/shape/shape.go`) for a files submission whose written and formatted `intent.md` has a `## Data stores` line: after the fixers and the existing contract-refusal check of an unchanged refused candidate, before the opt-in decision check, the step self-check and readiness. Refine is unchanged and runs no data-store gate.
- Problems, in this order, each one line:
  1. `- ## Data stores declares no key` when the section has no valid key line;
  2. for each `- ` line that is none of the three forms, in section order: `- not a ## Data stores item: <the line as written>`;
  3. for each invalid item, in section order, its first failing condition: `- <path>: no file tracked at HEAD has this path`, `- <path>: acceptance.feature and the step files listed under Acceptance do not contain <text>`, `- <path>: ## Decisions has no line <n>`, `- <path>: decision <n> does not name <path>`;
  4. for each uncovered reference, in reference order: `- <file> references <key> (line <n>)` or `(lines <n>, <m>, ...)` followed by `; no ## Data stores item covers it`.
- With at least one problem nothing is published for this submission and its feedback (the tool result; external Shape: the next round's feedback) is exactly the headline
  `Data stores: <N> problem(s) with where the data of the declared keys lives; nothing was published. Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. Resubmitting this candidate unchanged is refused again.`
  (N = number of problem lines) followed by the problem lines, joined by single newlines with nothing after the last. For the acceptance fixture's package that covers only `db/memberships.csv` and `lib/account.js` the lines are exactly
  `- exports/1.json references account_id (line 1); no ## Data stores item covers it`, `- exports/2.json references account_id (line 1); no ## Data stores item covers it`, `- lib/exports.js references account_id (lines 1, 4); no ## Data stores item covers it`.
- It is an invalid submission under SHP-4: one `submission_refused` event with gate `data_stores` whose problems are the problem lines; it counts on the shared invalid-submission counter; accumulated proposals stay; the written files stay as after other not-ready feedback. The refused candidate reaches no readiness or contract review, supplies no readiness evidence and is never acknowledgeable: an unchanged resubmission is refused again with the same text. At the third invalid submission Shape ends as today with `intent/not_ready: the Intent is not ready to build` and the problem lines (exit 1).
- A candidate with a section and no problems continues exactly as today (step self-check, readiness, contract review, acknowledgment).

## Shaping instructions
After the existing test-runner observer guidance in `ShaperInstructions` (`cli/shape/context.go`, native and external Shape), the shaper's instructions add exactly this paragraph, ending with a newline. Refine's instructions do not carry it, like the other Shape-only guidance.

```text
Data stores: for a request about an entity's data (for example deleting, exporting or moving an account's data), establish where that data lives before you write scope and acceptance: its schemas, the associations its model reaches, and every other store keyed by the entity's id (other tables, files, directories, indexes), found by searching the repository for each spelling of the id key. Record them in a ## Data stores section of intent.md: a line - key `<key>` for each spelling, then, for each file or directory (a path ending in /) that references a key, either - `<path>`: in scope, observed by `<text>`, where acceptance.feature or a step file listed under Acceptance contains <text>, or - `<path>`: excluded by decision <n>, where line <n> of ## Decisions names <path> and keeps its source. Shape refuses a candidate whose section leaves uncovered a file tracked at HEAD that references a declared key; the Build's independent review checks the candidate against the same scan.
```

## Review: the same evidence, and no silent approval
- Evidence: when the approved Intent has a `## Data stores` section with at least one valid key, the review authority (`materialOf` in `cli/build/material.go`, used by the native and the external reviewer) gets, right after the `Acceptance: <command>.` line and its blank line of the `# Protected paths and configured commands` block, this block followed by a blank line:
  ```text
  # Data stores

  Keys declared under the approved Intent's ## Data stores: <keys joined by ", ">
  Files tracked at the Build's start commit that reference a declared key, and the item that covers each:
  <one line per reference>
  A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.
  ```
  Each reference line is `- <file> references <key> (line <n>)` / `(lines <n>, ...)` followed by `: covered by <the covering item line without its leading "- ">` or `: not covered`; with no reference the single line is `- none`. Item validity uses the Build's start commit and the approved acceptance files in the checkout. Without the section (or without a valid key) the authority is unchanged.
- Verdict rule: the uncovered files are the distinct files with at least one uncovered reference, in path order. In `reviewRun.validate` (`cli/build/review.go`, native and external), when there are uncovered files and some of them has no finding with `severity` `blocking` and exactly that `path`, the verdict gets the problem
  `each data store the approved Intent omits needs a blocking finding at its path; the Intent neither scopes it nor excludes it by a Decision: <those files joined by ", ">`
  placed after the existing `a changes verdict needs at least one blocking finding` / `an approve verdict cannot have blocking findings` problem and before the no-product-defect check. It goes back through the existing rejected-verdict allowance as `invalid verdict:\n<problems>`; an approval is therefore never valid while a file is uncovered, and a `changes` verdict with those blocking findings stops the Build as `candidate/review_blocked` with its `review: <path>:<line>: <message>` lines, as today. Explicit resume recomputes the same evidence from the same start commit.
- Reviewer prompt: `cli/agent/prompts/reviewer.md` gets this paragraph immediately before the paragraph that starts `Call submit_review` (the external reviewer receives the evidence block and its closing instruction in its authority; `reviewTask` is unchanged):

```text
Data stores: when the authority has a # Data stores section, it lists every file tracked at the Build's start commit that references a key the approved Intent declares under ## Data stores, with the item that covers it. A file listed as not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path, because you cannot change the approved Intent; Kogen refuses a verdict without that finding. When the approved Intent deletes, exports, moves or changes an entity's data and has no ## Data stores section, search the repository for the entity's id key yourself: a store keyed by it (another table, file, directory or index) that the Intent neither scopes nor excludes by a Decision is a blocking finding at that store's path.
```

## Unchanged and out of scope
- Kogen cannot tell mechanically that a request concerns an entity's data: an Intent without the section is guided by the shaping and reviewer instructions only, and the scan finds only the declared key spellings. Detection is not exhaustive; coverage is per file, so a file holding several stores (one schema file with several tables) is one item.
- Approval, Refine, readiness and its record, acknowledgment, the contract check, the unwritten-tests and runner-observer gates, Build, Resume, recovery and commit are unchanged. Accumulated suites of earlier Intents under `features/steps/` are not changed; `features/steps/go_driver_support.js` is used unchanged.
- The Build updates tests and goldens that pin the shaper's instructions (for example `cli/shape/testdata/force_ordinary_golden.json`) and the reviewer prompt (for example `cli/build/testdata/reviewretry/*.wire.json`, `cli/build/testdata/context-external-golden.json`) to the new paragraphs.
- Documentation: `spec/prose/02-shaping.md` SHP-5 describes the optional `## Data stores` section and its items, and SHP-8 the `data_stores` gate (feedback, gate name, not acknowledgeable, `intent/not_ready` at the third); `spec/prose/06-reviewing.md` REV-2 adds the Data stores evidence and REV-4 the verdict rule. No new requirement ids; `sh check.sh` in `spec/` must still pass.

## Decisions
- Before writing scope and acceptance for a request about an entity's data, shaping establishes where that data lives in the repository: schemas, associations and any store keyed by the entity's id (source: request)
- Each such store is put in scope with acceptance that observes it, or excluded by a recorded Decision with its source (source: request)
- Review checks scope against the same evidence instead of approving silently, and an omitted store with no Decision is a finding (source: request)
- The behaviour is general to any stack, not tied to Rails, and uses no hidden-test or benchmark content (source: request)
- Regression tests are synthetic only: a small fixture repository whose entity's data also lives in a store its model does not reach, where shaping or review fails without the store in scope or a Decision and both pass with it (source: request)
- No new CLI command, flag or config key, and no raised timeouts or limits (source: request)

## Source comparison
- addressed: Problem (a request about an entity's data is scoped only to what the model reaches; stores keyed by the entity's id in other tables, files or indexes are dropped and review approves silently) — the `## Data stores` section, the Shape gate and the review rule; scenarios 1-3 reproduce it with a model (`lib/account.js`, reaching `db/memberships.csv`) and a store it does not reach (`exports/1.json`, `exports/2.json`, written by `lib/exports.js`).
- addressed: Need 1 "establishes where that data lives: schemas, associations, and any store keyed by the entity's id ... in scope with acceptance that observes it, or a sourced Decision excluding it" — shaping paragraph, model-free key scan, `in scope, observed by` and `excluded by decision <n>` items, `data_stores` refusal; scenario 1.
- addressed: Need 2 "Review checks scope against the same evidence ... an omitted store with no Decision is a finding" — the same scan in the review authority, the reviewer paragraph and the verdict rule; scenario 2 (approval refused, Build stops `candidate/review_blocked`) and scenario 3 (covering Intent approved and landed).
- addressed: Need 3 "general to any stack, not tied to Rails, no hidden-test or benchmark content" — a text scan of Git-tracked files with declared key spellings; the fixture is plain JavaScript, CSV and JSON.
- addressed: Need 4 "synthetic regression tests: without the store in scope or a Decision, shaping or review fails; with it, both pass" — scenario 1 (Shape refuses, then publishes the covering package), scenarios 2 and 3 (review refuses, then approves).
- addressed: Need 5 "No new CLI command, flag or config key; no raised timeouts or limits" — none added; the new section is Intent content, the gate uses the existing three-submission counter and the review rule the existing rejected-verdict allowance.
- addressed: Evidence (issue 09096a6e, codex-helpers/fbp1, codex-helpers/fbc1o3, e746e82, eu2, 2+2) and the measured numbers — kept as motivation in the prose; not fixtures and not claimed as results of this Build.
- omitted: detection for Intents that declare no section (instructions only), Refine and approval gating, and per-table coverage inside one file — stated under Unchanged and out of scope.

## Tests
- The section grammar, the scan (word boundaries, `.kogen/` exclusion, binary files, line lists), item validity in order, coverage by the first valid item and directory prefixes, and the problem and evidence line formats: table tests over temporary Git repositories in the package that implements them (integration)
- A candidate whose section leaves files uncovered is refused with the exact headline and problem lines, gate `data_stores`, before readiness; it is refused again when resubmitted unchanged and ends `intent/not_ready` at the third attempt; a covering candidate and a candidate without the section continue as today: scripted-provider tests in cli/shape (integration)
- External Shape receives the same refusal as its next round's feedback: a scripted external-session test in cli/shape (integration)
- Shaping instructions carry the Data stores paragraph and Refine's do not: extend the existing shaping-guidance test and update the pinned golden (regression)
- The review authority carries the exact Data stores block when the approved Intent declares a key and is unchanged otherwise: a cli/build material test (integration)
- A verdict without a blocking finding at each uncovered file is rejected with the exact problem, a changes verdict with them stops `candidate/review_blocked`, and a covering Intent's approval lands, for the native and the external reviewer: scripted reviewer tests in cli/build (integration)
- The reviewer prompt carries the Data stores paragraph: update the reviewer prompt goldens (regression)
- End to end through the installed CLI on the synthetic fixture: acceptance scenarios 1-3 (scenario)
- Intents without a section, approval, Refine and the other Shape gates are unchanged: existing Go tests, spec checks and all configured checks (existing)

## Feasibility
- Scratch checks outside Kogen's probe records (external read-only session, scratch directories outside the checkout): `git grep -I -n -w -F -e account_id HEAD -- . ':(exclude).kogen'` on the fixture reports exactly db/memberships.csv:1, exports/1.json:1, exports/2.json:1, lib/account.js:1, lib/exports.js:1 and :4, and not `my_account_id`, `account_ids` or `.kogen/` content; with the bundled-version Cucumber the fixture package's step file fails the purge scenario without lib/purge.js (`Cannot find module`), passes it with the scripted builder's lib/purge.js, and leaves the fixture files unchanged; a strict dry run binds all 19 steps of this feature with no undefined or ambiguous step; the observer controls below gave `accepted` (exit 0) and `rejected` (exit 1), and a deliberately weakened observer made the bad control fail.
- The controls below check that the feature's literals are the stated formats applied to the fixture (refusal, both evidence blocks, rejected verdict, blocked lines) and that the observers accept known-good observations and reject independently damaged ones (old publication of the associations-only package, missing or extra refusal lines, wrong line numbers, wrong gate or event count, missing guidance, missing or wrong evidence, accepted first approval, wrong or missing rejection, extra review requests, a missing approved review line, wrong outcomes and commit counts). They are observer controls only, not product evidence.
- evidence: {"id":"data-stores-observer","kind":"observer","inputs":["features/steps/k_shape_data_stores_steps.js",".kogen/intents/k-shape-data-stores/acceptance.feature"],"observers":["features/steps/k_shape_data_stores_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k_shape_data_stores_steps.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k_shape_data_stores_steps.js --control bad","exit":1,"output":"rejected\n"}]}
