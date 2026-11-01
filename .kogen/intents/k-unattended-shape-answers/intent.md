# Leave pending shape questions in questions.json

Slug: k-unattended-shape-answers
Model: not applicable — the new file mirrors the existing pending-question state of state.json; no new state machine or transition
Acceptance:
- .kogen/intents/k-unattended-shape-answers/acceptance.feature
- features/steps/k_unattended_shape_answers_steps.js

Fix K-UNATTENDED-SHAPE-ANSWERS (change_type: fix): an unattended shape stops on questions nobody will answer. Today, when `kogen intent shape <slug> <file|->` has questions, it prints them (SHP-6), ends with `Or enter all: recommended to use every question's recommended option.` and exits 5. An unattended caller (a launcher with no terminal, overnight) can learn this only by scraping that prose, and exit 5 alone is ambiguous (`intent/exists` also exits 5). Evidence: seven unattended builds on 31 Oct 2026 (Kogen v0.1.0-dev.3e759e88) ended EXIT=5 at "Or enter all" (k-baseline-per-base, k-round-targeted-tests twice, l-request-budget, l-shell-hang, k-fix-failing-check, l-request-count, plus older l-endturn, l-prefixlog, l-thinking shape runs); their recommended answers were acceptable under the 31 Oct decision "kogen items auto-approved when consistent with principles", so only the stop cost time.

After this change every shape that stops on pending questions also leaves them, with their recommended options, in one documented machine-readable file, `.kogen/local/shaping/<slug>/questions.json`, written in Kogen's existing version 1 checkout facts envelope (docs/checkout-facts.md). Answering stays an explicit caller act through the existing input, recorded with the Intent exactly as today. No new command, flag, option, setting or environment variable; the agreed CLI stays as it is. Interactive behavior stays as it is: the printed question block, the answer formats and exit 5 are unchanged, and Kogen does not detect terminals (the file is written whether or not a terminal is attached).

### The questions file

- Path: `.kogen/local/shaping/<slug>/questions.json`, beside the existing `state.json` in the same 0700 shaping directory; the file is a regular file with mode 0600, replaced as a whole (write a temporary file in the same directory, then rename), never edited in place.
- Content: one JSON object followed by a newline, the version 1 envelope with exactly the keys `schema_version` (1), `kind` (`"questions"`), `checkout` (`{id, root, git_dir}` of this checkout, exactly as `kogen context` reports it: `project.Checkout(root)`), `data` and `error` (`null`).
- `data` has exactly `slug` (the Intent slug) and `questions`: exactly the pending (unanswered) questions of the latest round, in ascending number order — the same questions the run prints. Each question has exactly:
  - `number`: the 1-based question number, as printed and as used in `<n>: <answer>` lines;
  - `question`: the question text;
  - `kind`: `"handoff"` for an authentication or security handoff question, otherwise `"product"` (an omitted kind is `"product"`);
  - `options`: the options in printed order, each exactly `{letter, label, recommended}` where `letter` is `a`, `b`, … as printed, `label` the option text and `recommended` a boolean that is true exactly when the option is printed with `(recommended)` (an omitted or false `recommended` is false); an empty array for a question without options;
  - `recommended`: the letter of the question's first recommended option — the option `all: recommended` picks — or `null` when it has none.
- Example, for a round whose two questions are both pending:
  `{"schema_version":1,"kind":"questions","checkout":{"id":"…","root":"…","git_dir":"…"},"data":{"slug":"answers-demo","questions":[{"number":1,"question":"Which wording should the banner use?","kind":"product","options":[{"letter":"a","label":"Keep the current wording","recommended":false},{"letter":"b","label":"Use the shorter wording","recommended":true}],"recommended":"b"},{"number":2,"question":"Should the banner show the unread count?","kind":"product","options":[{"letter":"a","label":"Show the count","recommended":true},{"letter":"b","label":"Hide the count","recommended":false}],"recommended":"a"}]},"error":null}`

### When it is written and removed

- Written, before the questions are printed, every time `kogen intent shape` ends with exit 5 because questions are pending: when the shaper submits a new round of questions (`outQuestions` in `shaping.shape`, cli/shape/shape.go), and when an answer input leaves questions of the pending round unanswered (the reprint without a model request in `shapeRun`). After `2: a` answers only question 2 of two, the file lists only question 1.
- Removed when shaping ends ready (exit 0), together with `state.json`. Other endings (provider failure, not ready, blocked, refused answers such as `intent/answers_invalid`) leave it as it is: in those cases `state.json` still holds the same pending questions, so the file still describes them. Deleting `.kogen/local/shaping/<slug>/` still discards pending questions, the file included.
- Exit 5 with this file present tells an unattended caller, without parsing prose, that shape stopped on questions, which ones are pending and their recommended options.

### Unchanged

- The printed question block (SHP-6), the handoff line, the sample `printf` line and `Or enter all: recommended to use every question's recommended option.`; exit 5.
- Answering: `<n>: <letter or your words>` lines and the existing special input `all: recommended` on stdin (`-`) or in a file; `intent/answers_invalid` and `intent/answer_option_invalid` (exit 2). No bare `all` input and no automatic answering are added: feeding `all: recommended` remains the caller's explicit act.
- Recording: the round's `inputs`, `answers` and `resolved_answers` in the source receipt `.kogen/local/provenance/<slug>/current.json`, as for any other answer; `kogen intent approve` still refuses pending questions with `intent/questions_pending` (exit 5).

### Documentation

- docs/checkout-facts.md gains a section for pending shape questions that names `.kogen/local/shaping/<slug>/questions.json`, its envelope (`kind` `questions`), the `data` fields above, when it is written and removed, and that answering stays explicit with `all: recommended` or `<n>: <letter>` lines through `kogen intent shape <slug> -`.
- spec/prose/02-shaping.md SHP-6 names `.kogen/local/shaping/<slug>/questions.json` as where pending questions and their recommended options are left, pointing to docs/checkout-facts.md for its fields.

## Decisions
- No new command, flag or option; the agreed CLI stays as it is (source: request)
- The pending questions and their recommended options are left in a stable, documented, machine-readable place produced by Kogen: `.kogen/local/shaping/<slug>/questions.json` in the version 1 checkout facts envelope (source: request)
- Answering with the recommended options remains an explicit caller act through the existing `all: recommended` input, recorded with the Intent like any other answer (source: request)
- Interactive behavior stays as it is: the printed questions and exit 5 do not change (source: request)

## Source comparison
- addressed: "An unattended caller can tell, without parsing prose, that shape stopped on questions, and which ones and their recommended options are" — exit 5 plus `.kogen/local/shaping/<slug>/questions.json` listing pending questions, options and `recommended`; source request Need; contract prose "The questions file" and acceptance scenarios 1–2.
- addressed: "in a stable, documented form already produced by Kogen" — the version 1 checkout facts envelope of docs/checkout-facts.md, kind `questions`; source request Need; contract prose and scenario 4.
- addressed: "Answering with the recommended options remains an explicit caller act, recorded with the Intent like any other answer" — existing `all: recommended` input and source receipt rounds; source request Need; contract "Unchanged" and scenario 3.
- addressed: "Interactive behaviour stays as it is" and "No new command, flag or option; the agreed CLI stays as it is" — printed block and exit 5 unchanged, no terminal detection; source request; contract prose, Decisions and scenarios 1–2.
- addressed: acceptance evidence "run without a terminal, leaves the questions and their recommended options in a documented machine-readable place and exits with its documented status; feeding \"all\" through the existing input answers them and the Intent records the answers" — installed release driven through pipes; exit 5; then `all: recommended` (the existing input the request calls "all"), receipt records inputs/answers/resolved answers; source request Acceptance evidence; scenarios 1–3.
- addressed: problem text "Answer one per line as <n>: <letter or your words> ... Or enter all: recommended to use every question's recommended option.", exit 5, re-run shape with `-` on stdin; source request Problem; contract "Unchanged".
- omitted: a bare `all` input; the request names the existing input, which is `all: recommended`; source request; contract "Unchanged".
- omitted: specific builds and logs (k-baseline-per-base, k-round-targeted-tests, l-request-budget, l-shell-hang, k-fix-failing-check, l-request-count, l-endturn, l-prefixlog, l-thinking, ~/logs/s-web-harden, Kogen v0.1.0-dev.3e759e88, the 31 Oct auto-approval decision) are historical evidence, not behavior to reproduce; source request Evidence; contract prose.

## Tests
- A shape that stops on new questions writes questions.json with the pending questions, kinds, options and recommended letters in the version 1 envelope (mode 0600) while its printed block and exit 5 stay unchanged: acceptance scenario "A shape that stops on questions leaves them and their recommended options in questions.json" (scenario)
- A handoff question is listed with kind handoff and a question without options with an empty options array and recommended null: a Go test in cli/shape/shape_test.go that stops on such a round and reads questions.json (regression)
- An answer input that leaves questions pending rewrites questions.json with only the unanswered questions: acceptance scenario "Answering some questions leaves only the still pending ones in questions.json" (scenario)
- all: recommended through the existing input answers the pending questions, the source receipt records inputs, answers and resolved answers, and the ready shape removes questions.json with state.json: acceptance scenario "all: recommended through the existing input answers the pending questions and the receipt records them" and a Go test in cli/shape/shape_test.go that a ready shape leaves no questions.json (scenario)
- docs/checkout-facts.md and SHP-6 document the questions file: acceptance scenario "The questions file is documented with Kogen's machine-readable facts and the shaping questions" (scenario)

## Feasibility
- Local timing outside Kogen probes: `sh packaging/package.sh` on a scratch copy of HEAD took 12.8 s wall; the draft acceptance run against that HEAD archive took 18 s, so the installed-release flow fits Shape's 120-second acceptance bound even when the harness packages once more.
- Draft acceptance against the unchanged HEAD release (scratch outside the checkout): all 12 existing-behavior steps passed (exit 5 and printed blocks of both question stops, exit 0 and `Next: kogen intent approve answers-demo`, receipt inputs `["2: a\n","all: recommended\n"]`, answers `{"1":"b","2":"a"}`, resolved answers, state.json removed); only the four new questions.json/documentation assertions failed, each because the file or text is absent.
- evidence: {"id":"questions-file-observer","kind":"observer","inputs":["features/steps/k_unattended_shape_answers_steps.js"],"observers":["features/steps/k_unattended_shape_answers_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_unattended_shape_answers_steps.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_unattended_shape_answers_steps.js --control bad","exit":1,"output":"rejected\n"}]}
