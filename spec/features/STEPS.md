# Step vocabulary, fixtures and the fake ChatGPT server

Kogen's own scenarios execute against the real `kogen` command: the installed release where the Background says "the installed kogen command", a real Git, real processes, and a fake ChatGPT server. The implementer writes one step definition per pattern below in the Cucumber 13.3.0 harness; a step definition checks only what its sentence says, and expected values live in the feature files. `tools/check.mjs` checks that every step matches exactly one pattern. That is a well-formedness check, not execution evidence: only running the scenarios counts (REL-4).

## Conventions

- **Node distribution.** Only the missing-Node installer scenario serves a local HTTP catalog and a tarball of the actual pinned Node installation running the suite. The harness curl wrapper redirects only `https://nodejs.org/dist/` requests in that scenario; real curl, tar, the unmodified installer and the installed Node binary execute. The catalog includes a newer non-LTS entry to check LTS selection. This checks installation behavior, not external Node service availability.

- **Project.** "the project" is the most recent Git project a Given step created; relative paths are relative to its root; commands run there unless a step names a folder.
- **Fixture installs.** Commands that install npm packages use the suite's own npm cache (`npm_config_cache`, offline first), so the fixtures' pinned Cucumber 13.3.0 needs no network.
- **Kogen home.** "a clean Kogen home" gives every command an empty temporary `HOME` (`{home}`); no real credentials ever exist there.
- **Placeholders in expected text.** `{sha8}`, `{sha256}`, `{id8}` lowercase hex of that length; `{build_id}` the last Build's id; `{n}` an integer; `{dur}` a duration like `6m12s`; `{model}`, `{effort}` configured values; `{ident}` `Name <email>`; `{url}` one URL; `{abs:<rel>}` the absolute path of `<rel>` in the project; `{home}`; `{path_node}` the absolute path of the `node` that the step "node 22 or newer is on PATH" put on `PATH`. All other text matches byte for byte; `stdout is:` compares all of stdout; `stdout contains:` compares a multiline section, preserving placeholder identity checks.
- **Signals.** "the kogen command" is the Go process (signalled like a terminal would); "the Kogen core" is its Elixir child.
- **Initialized projects.** "the project is initialized" commits the configuration template unchanged and the `.kogen/local/` ignore line, as `kogen init` writes them in an empty repository without commits, without running `init` (whose own behavior chapter 01 tests); "and configured" then commits the fixture's configuration.
- **Project configuration.** "the project config sets <key> to <value>" edits `.kogen/project.yaml` (the value is YAML) and commits the file, so it must come before an Intent is approved (the file is part of the approval). The steps "the acceptance command is replaced by fixture runner" and "records its environment" swap what the harness executes; they do not touch `.kogen/project.yaml`. "the readiness command is running" waits until the acceptance command of a readiness dry run has started.
- **Process groups.** "the Build command's process group" is the group of the active command of the Build, of shaping or of approval; "processes started by the Build's commands" are the members of every process group the Build's commands ran in. The test records them when the commands start and checks them itself.
- **Review requests.** "the review request" is the request with the `submit_review` tool; "review request <n>" is the n-th reviewer model request. An independent review stage retains its number through targeted verification repairs.
- **Intent steps.** "the Intent is shaped" writes the fixture's Intent files; "is approved" also records an approval for their hash; "has landed" approves the Intent and builds it with script `build-correct-first-try`, so its commit exists and its approval is gone (GIT-8). "the hash of its acceptance baseline" is the hash that AUT-2 defines, computed by the step itself.
- **Pause points.** `builder request in flight`, `tool command running` and `review approved` are points of the fake server's script. `git commit running` is reached when the Build's `git commit` has started and is held by the step "a pre-commit hook that sleeps for <n> seconds"; the test, not the server, waits for it.
- **Live projects.** In the `@live` outline, "example" is the example app in `examples/` of the repository, copied into the run folder with a fixed baseline commit; "kogen" is the candidate Kogen source (REL-3); "external" is a real project kept outside the repository, run with its own settings file (`@external`, REL-2).
- **Waiting.** "has sent the feedback of verification pass <n>" waits until the builder request carrying that pass's feedback has reached the fake server.
- **Tags.** `@live` scenarios are the real-use script, not the deterministic suite.

## Project fixtures

| Name | Content |
| --- | --- |
| Intent `is-even-outline` | one Scenario Outline with three Examples rows for the review-card count |
| `py-calc` | `README.md`, `calc.py` with `add`, `tests/test_calc.py` (unittest), `features/steps/calc_steps.js` (existing step definitions running `python3 -c`), `tools/format.py` (a formatter) and its rules `.style.cfg`, `.gitignore` with `__pycache__/`; one commit. "initialized and configured" sets `checks: [{name: test, run: python3 -m unittest}]`, the Cucumber acceptance runner, `steps_dir: features/steps`, `protect: [.style.cfg]`, and commits. |
| `empty-repo` | `git init`, no commit. |
| `notes` | `README.md` (plain notes), `CLAUDE.md`, `notes.txt`, `docs/index.md`; no build tool, no tests; one commit. |
| `ex-app` | a Mix project without dependencies: `mix.exs`, `.formatter.exs`, `lib/ex_app.ex` (formatted, compiles with one unused-variable warning), `test/ex_app_test.exs` (passes), `.gitignore` with `/_build/` and `/deps/`; one commit. |
| `node-app` | `package.json` with scripts `test` (`node --test`, passes) and `lint` (`node lint.js`, exits 2), devDependency `@cucumber/cucumber` 13.3.0 and its `package-lock.json`; `features/step_definitions/app_steps.js`; `docs-check.js` (exits 0) named in `README.md`; `.gitignore` with `node_modules/`; one commit. |
| Intent `is-even` | title "Add an is-even helper"; scenarios Even numbers, Odd numbers, Non-integers; new step file `features/steps/is_even_steps.js`; no model; a `## Tests` section with two `unit` lines (as in the chapter 02 example). Variants `is-even-*` break exactly the rule their name says (`is-even-no-tests` has no `## Tests` section). |
| Intent `counter-with-model` | a bounded counter with `model.qnt`, invariant `NeverNegative`, seed 7, 500 samples, 30 steps. |
| Fixture runners | acceptance commands that emit the named defective report (`reports-undefined`, `reports-skipped`, `omits-one-scenario`, `reports-one-twice`, `writes-no-report`, `exits-1-all-passed`) and `hangs` (sleeps 600 seconds). |

## Fake ChatGPT server

A loopback server reached through `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` (GPT-11). It records every request and plays a script of streamed responses (text, fragmented tool calls, `submit` or `submit_review` calls, errors; a script starts again for each new conversation), optionally pausing at a named point until the test says "continues". Unless the name says otherwise, every `build-*` script answers each review with `approve` and the note `calc.py:12: the docstring could name TypeError`.

| Script | Behavior |
| --- | --- |
| `shape-failed-and-undefined-step` | submits a feature whose assertion fails before an undefined step in the same scenario |
| `init-proposes-nothing` | answers the `init` request (the one with the `submit_configuration` tool) with empty lists |
| `init-proposes-docs-check` | answers it with the check `{name: docs, run: node docs-check.js}` |
| `init-invalid-twice` | answers it twice with a check named `Docs Check` |
| `init-corrects-dependency-protect` | first protects `.formatter.exs` and dependency-only `mix.exs`, then returns the valid formatter-only correction |
| `init-proposes-setup` | answers it with setup `mkdir seeded`, `echo run >> runs.txt` and `true` |
| `shape-ready-is-even` | reads two files, submits `is-even`, acknowledges unchanged baseline-red observations |
| `shape-narrow-retry` | submits complete artifacts with a missing decision source, corrects only prose, then acknowledges unchanged red without losing feature/steps |
| `shape-observed-repair` | submits a hook fixture defect, repairs it after observed feedback, then acknowledges legitimate product-red observations |
| `refine-title` | submits only the existing Intent prose with a clarified title; all other artifacts are reused |
| `refine-constraint` | reports that the correction needs an unsupported new step file, without changing the draft |
| `shape-asks-one-empty-final` | complete streamed question tool followed by empty final output metadata; the question still reaches the caller |
| `unfinished-tool-empty-final`, `malformed-tool-empty-final` | unfinished added or malformed done tool followed by empty final output; retained invalid output cannot write unauthorized.txt |
| `shape-asks-one`, `shape-asks-two` | submits one or two UI/UX questions |
| `shape-asks-one-then-writes` | one question; after the answer, submits `is-even` citing `(source: answer 1)` |
| `shape-asks-two-then-writes` | two questions; after both answers, submits `is-even` citing both answer numbers |
| `shape-invalid-three-times` | three submissions with a forbidden path |
| `shape-protected-conflict` | reports a required edit to the configured protected `.style.cfg` path |
| `shape-edits-existing-step-file` | submits `is-even` with an edit to the existing `features/steps/calc_steps.js` |
| `shape-not-ready-then-asks` | submits `is-even` with an undefined step; after the readiness feedback it asks one UI/UX question |
| `shape-undefined-step`, `shape-failing-invariant` | valid format; readiness fails as named; the same files are submitted 3 times (SHP-4) |
| `shape-probes-then-writes` | `probe python3 -c 'print(1.5 % 2)'`, then submits `is-even` with the probe in `## Feasibility` |
| `shape-probe-hangs-then-writes` | `probe sleep 600`, then submits `is-even` recording the timed-out probe. Its SHP-10 scenario uses a test-only Go driver around the actual installed core: it verifies the outgoing 300000 ms policy, shortens only that execution request's deadline to 200 ms, and returns the real production executor's timeout result. The scenario asserts process-group death, scratch removal and continued shaping. This composes policy and real timeout-path evidence; it does not measure 300 seconds of elapsed time. |
| `build-reports-blocker` | builder-only protected-path report with evidence, then forbidden later write/finish in the same response; stops as builder-reported, not independently proven |
| `build-correct-first-try` | correct implementation; `finish` |
| `build-wrong-then-repair` | wrong `is_even`; after feedback, the correct one |
| `build-wrong-forever` | always a wrong implementation of `calc.py` and `tests/test_calc.py` |
| `build-unformatted-then-formatted` | correct but unformatted, then formatted |
| `build-runs-command` with command `C` | `shell C`, then like `build-correct-first-try` |
| `build-with-background-server` | `shell python3 -m http.server 8765 > server.log 2>&1 &`, then a fixture-side wait `shell for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.1; done`, then the asserted `shell curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8765/`, then leaves the server running and continues like `build-correct-first-try` |
| `build-tries-path` with path `P` | `write_file P`, then like `build-correct-first-try` |
| `build-three-calls-fragmented` | one response: `write_file a.txt hello`, `shell cat a.txt missing.txt`, `bogus_tool`, split across many stream events |
| `build-context-overflow` | edits `calc.py`, then a context-length error |
| `build-then-500-always` | one tool round, then 500 on every request |
| `build-review-changes-then-fixed` | review 1 `changes` (`calc.py:3: is_even accepts floats; the Intent says non-integers raise TypeError`), fix, review 2 `approve` |
| `build-adds-unrequested-option-then-removes-it` | adds `calc_config.py`; review 1 `changes` (`calc_config.py:1: not asked for by the Intent`); the builder deletes it; review 2 `approve` |
| `build-leaves-old-helper-then-removes-it` | the fixture has an unchanged `legacy_parity.py`; the reviewer reads it and finds `legacy_parity.py:1: obsolete parity helper; remove it`; the builder deletes it; review 2 `approve` |
| `build-review-invalid-twice` | two malformed verdicts |
| `build-review-demands-baseline-change` | every review asks to change the acceptance feature; the builder tries `write_file` on it |
| `401-then-ok`, `500-always`, `stream-cut-then-ok`, `usage-limit` (resets 2030-01-01T00:00:00Z), `model-unavailable`, `400-bad-request` | as named; where they succeed, like `shape-ready-is-even` |

## Patterns

One JavaScript regular expression per line.

```steps
^readiness setup records executions outside the checkout$
^readiness has executed (\d+) times?$
^the original refinement readiness receipt has status "([^"]*)"$
^the caller refines "([^"]*)" with its current baseline and stdin:$
^no builder request was sent after review began$
^the Build records (\d+) review stages? and (\d+) verification pass(?:es)?$
^a local Node distribution serves the real pinned Node and a newer non-LTS catalog entry$
^the installer downloaded the catalog and selected LTS archive from the local Node distribution$
^the installed Node reports the real fixture version$
^HEAD\ has\ (\d+)\ new\ commit$
^HEAD\ has\ no\ commit\ by\ Kogen$
^HEAD\ is\ unchanged$
^a\ Git\ project\ from\ fixture\ "([^"]*)"$
^a\ Git\ project\ from\ fixture\ "([^"]*)"\ in\ the\ folder\ "([^"]*)"$
^a\ clean\ Kogen\ home$
^a\ disposable\ repository\ with\ the\ candidate\ Kogen\ source\ and\ an\ ordinary\ Git\ baseline$
^a\ fresh\ clone\ of\ "([^"]*)"$
^a\ fresh\ user\ home\ on\ "([^"]*)"$
^a\ merge\ is\ in\ progress$
^a\ pre\-commit\ hook\ that\ appends\ a\ line\ to\ "([^"]*)"\ and\ stages\ it$
^a\ pre\-commit\ hook\ that\ sleeps\ for\ (\d+)\ seconds$
^an\ empty\ folder\ "([^"]*)"$
^another\ commit\ is\ made\ on\ HEAD$
^commit\ signing\ is\ configured\ with\ a\ missing\ key$
^commit\ signing\ is\ configured\ with\ a\ test\ SSH\ key$
^every\ tool\ call\ in\ the\ run\ log\ ran\ once$
^git\ user\.name\ and\ user\.email\ are\ not\ set$
^kogen\ is\ gone\ and\ the\ project\ and\ \~/\.kogen\ are\ intact$
^neither\ stdout\ nor\ stderr\ contains\ the\ fake\ access\ token$
^no\ Intent\ named\ is\-even\ exists$
^no\ Kogen\ git\ invocation\ disabled\ signing\ or\ hooks$
^no\ Kogen\ git\ invocation\ used\ push,\ fetch,\ rebase,\ merge,\ cherry\-pick,\ reset,\ stash,\ switch,\ checkout\ or\ commit\ \-\-amend$
^no\ Kogen\ process\ had\ the\ fake\ access\ token\ in\ its\ arguments\ or\ environment$
^no\ Kogen\ process\ had\ the\ request\ text\ in\ its\ arguments$
^no\ Kogen\ process\ is\ alive\ and\ no\ credential\ token\ appears\ in\ any\ project\ or\ log\ file$
^no\ erl,\ elixir\ or\ go\ program\ is\ on\ PATH$
^no\ file\ in\ "([^"]*)"\ outside\ "([^"]*)"\ changed$
^no\ file\ under\ "([^"]*)"\ contains\ the\ fake\ access\ token$
^no\ process\ of\ the\ Build\ command's\ process\ group\ is\ running$
^no\ request\ contains\ "([^"]*)"$
^no\ request\ was\ sent\ after\ that\ command$
^mix\ test\ and\ go\ test\ \./\.\.\.\ pass\ on\ both\ platforms$
^no\ required\ scenario\ is\ pending,\ skipped,\ undefined\ or\ excluded\ and\ spec/check\.sh\ passes$
^no\ review\ request\ was\ sent$
^nothing\ is\ staged$
^request\ (\d+)\ has\ index-first\ source\ navigation\ for\ "([^"]*)"$
^request\ (\d+)\ contains\ "([^"]*)"$
^request\ (\d+)\ contains\ the\ text\ of\ the\ file\ "([^"]*)"$
^request\ (\d+)\ offers\ exactly\ the\ tools\ "([^"]*)"$
^request\ (\d+)\ uses\ model\ "([^"]*)"\ with\ effort\ "([^"]*)"$
^stderr\ contains\ "([^"]*)"$
^stderr\ matches\ "([^"]*)"$
^stderr\ contains\ core\ log\ lines$
^stdout\ contains\ "([^"]*)"$
^stdout\ contains:$
^stdout\ does\ not\ contain\ "([^"]*)"$
^stdout\ is:$
^stdout\ matches\ "([^"]*)"$
^the\ Build\ reaches\ "([^"]*)"$
^the\ Build\ runs\ at\ least\ one\ tool\ call,\ lands\ with\ review\ approved\ and\ the\ transcript\ records\ whether\ a\ repair\ happened$
^the\ Build\ stops\ within\ (\d+)\ seconds\ with\ exit\ code\ (\d+)\ and\ no\ commit$
^the\ Intent\ "([^"]*)"\ from\ fixture\ "([^"]*)"\ is\ approved$
^the\ Intent\ "([^"]*)"\ from\ fixture\ "([^"]*)"\ is\ approved\ and\ then\ edited$
^the\ Intent\ "([^"]*)"\ from\ fixture\ "([^"]*)"\ is\ shaped$
^the\ Intent\ "([^"]*)"\ from\ fixture\ "([^"]*)"\ has\ landed$
^the\ Kogen\ core\ logs\ at\ debug\ level$
^the\ acceptance\ command\ is\ replaced\ by\ fixture\ runner\ "([^"]*)"$
^the\ acceptance\ command\ records\ its\ environment$
^the\ authorization\ request\ used\ PKCE\ S256\ and\ a\ fresh\ state$
^the\ authorization\ server\ received\ (\d+)\ refresh\ request$
^the\ authorization\ server\ rejects\ refresh$
^the\ background\ command\ finishes$
^the\ browser\ completes\ sign\-in\ for\ "([^"]*)"$
^the\ browser\ sends\ a\ redirect\ with\ the\ wrong\ state$
^the\ caller\ approves\ "([^"]*)"\ with\ the\ hash\ from\ its\ review\ card$
^the\ caller\ approves\ "([^"]*)"\ with\ the\ hash\ of\ its\ acceptance\ baseline$
^the\ caller\ approves\ "([^"]*)"\ with\ the\ noted\ hash$
^the\ caller\ discards\ the\ edits\ listed\ in\ the\ last\ Build\ output$
^the\ caller\ discards\ the\ listed\ edits\ and\ builds\ again$
^the\ caller\ is\ signed\ in\ to\ ChatGPT$
^the\ caller\ is\ signed\ in\ to\ ChatGPT\ with\ an\ expired\ access\ token$
^the\ caller\ is\ signed\ out\ of\ ChatGPT$
^the\ caller\ noted\ the\ review\ card\ hash\ of\ "([^"]*)"$
^the\ caller\ ran\ "([^"]*)"$
^the\ caller\ ran\ "([^"]*)"\ with\ stdin\ "([^"]*)"$
^the\ caller\ reviews\ the\ Intent\ and\ step\ files\ and\ approves\ them$
^the\ caller\ runs\ "([^"]*)"$
^the\ caller\ runs\ "([^"]*)"\ in\ the\ background$
^the\ caller\ runs\ "([^"]*)"\ in\ the\ folder\ "([^"]*)"$
^the\ caller\ runs\ "([^"]*)"\ with\ stdin:$
^the\ caller\ runs\ "([^"]*)"\ and\ "([^"]*)"\ at\ the\ same\ time\ with\ stdin:$
^both\ commands\ exit\ 0$
^the\ caller\ runs\ "([^"]*)"\ with\ the\ sign\-in\ redirect\ URL\ on\ stdin$
^the\ caller\ runs\ kogen\ init\ and\ configures\ the\ project's\ commands$
^the\ caller\ runs\ kogen\ uninstall$
^the\ caller\ sends\ (SIGINT|SIGKILL)\ to\ the\ Kogen\ core$
^the\ caller\ sends\ (SIGINT|SIGTERM|SIGHUP|SIGKILL)\ to\ the\ kogen\ command$
^the\ caller\ shapes\ the\ project's\ request\ and\ answers\ any\ question\ it\ asks$
^the\ caller\ signs\ in\ with\ the\ real\ ChatGPT\ browser\ flow\ and\ kogen\ provider\ list\ shows\ the\ login$
^the\ caller\ starts\ the\ Build\ and\ sends\ SIGINT\ during\ it$
^the\ candidate's\ deterministic\ suite\ passes\ with\ an\ isolated\ HOME\ and\ no\ real\ credentials$
^the\ candidate\ is\ packaged,\ installed\ into\ a\ separate\ prefix\ and\ the\ change\ is\ observed\ outside\ its\ checkout$
^the\ committed\ file\ "([^"]*)"\ contains\ "([^"]*)"$
^the\ environment\ variable\ "([^"]*)"\ is\ "([^"]*)"$
^a\ clean\ checkout\ of\ the\ release\ commit$
^the\ release\ built\ from\ that\ checkout\ reports\ the\ commit's\ short\ hash$
^the\ exit\ code\ is\ (\d+)$
^the\ extracted\ archive\ has\ a\ broken\ core\ release$
^the\ fake\ ChatGPT\ authorization\ server\ is\ running$
^the\ fake\ ChatGPT\ server\ continues$
^the\ fake\ ChatGPT\ server\ has\ sent\ the\ feedback\ of\ verification\ pass\ (\d+)$
^the\ fake\ ChatGPT\ server\ plays\ script\ "([^"]*)"$
^the\ fake\ ChatGPT\ server\ plays\ script\ "([^"]*)"\ pausing\ at\ "([^"]*)"$
^the\ fake\ ChatGPT\ server\ plays\ script\ "([^"]*)"\ with\ command\ "([^"]*)"$
^the\ fake\ ChatGPT\ server\ plays\ script\ "([^"]*)"\ with\ path\ "([^"]*)"$
^the\ fake\ ChatGPT\ server\ reaches\ "([^"]*)"$
^the\ fake\ ChatGPT\ server\ received\ (\d+)\ request$
^the\ fake\ ChatGPT\ server\ received\ (\d+)\ requests$
^the\ file\ "([^"]*)"\ contains:$
^the\ file\ "([^"]*)"\ contains\ "([^"]*)"$
^the\ file\ "([^"]*)"\ does\ not\ contain\ "([^"]*)"$
^the\ file\ "([^"]*)"\ does\ not\ exist$
^the\ file\ "([^"]*)"\ exists$
^the\ file\ "([^"]*)"\ has\ mode\ "([^"]*)"$
^the\ file\ "([^"]*)"\ holds\ a\ ChatGPT\ token\ "([^"]*)"$
^the\ file\ "([^"]*)"\ is\ a\ symlink\ into\ "([^"]*)"$
^the\ file\ "([^"]*)"\ is\ changed\ outside\ Kogen$
^the\ file\ "([^"]*)"\ is\ created\ and\ staged$
^the\ file\ "([^"]*)"\ is\ unchanged$
^the\ first\ line\ of\ stdout\ is\ "([^"]*)"$
^the\ folder\ "([^"]*)"\ does\ not\ exist$
^the\ folder\ "([^"]*)"\ exists$
^the\ full\ deterministic\ suite\ and\ the\ packaging\ run\ from\ that\ checkout$
^the\ installed\ Kogen\ shapes\ and\ builds\ one\ small\ Kogen\ change\ there$
^the\ installed\ core\ release\ is\ missing$
^the\ installed\ kogen\ command$
^the\ kogen\ command\ is\ still\ running$
^the\ readiness\ command\ is\ running$
^the\ last\ line\ of\ stdout\ matches\ "([^"]*)"$
^the\ new\ commit's\ message\ is:$
^the\ new\ commit\ changes\ exactly:$
^the\ new\ commit\ does\ not\ change\ "([^"]*)"$
^the\ new\ commit\ changes\ no\ path\ under\ "([^"]*)"$
^the new commit has the Intent title, the Kogen-Intent trailer, no AI attribution and a signature exactly as the host's Git configuration says$
^the\ new\ commit\ is\ signed$
^the\ path\ "([^"]*)"\ has\ uncommitted\ changes$
^the\ program\ "([^"]*)"\ is\ not\ on\ PATH$
^node\ 22\ or\ newer\ is\ on\ PATH$
^the\ project's\ own\ acceptance\ command\ and\ tests\ pass\ on\ the\ new\ commit\ without\ Kogen$
^the\ project\ config\ sets\ "([^"]*)"\ to\ "([^"]*)"$
^the\ project\ has\ a\ build\ lock\ of\ a\ process\ that\ is\ not\ running$
^a\ commit-msg\ hook\ that\ rejects\ every\ message$
^the\ project\ is\ initialized$
^the\ project\ has\ the\ Kogen\ configuration\ and\ ignore\ line\ written\ but\ not\ committed$
^the\ project\ is\ initialized\ and\ configured$
^the\ recorded\ acceptance\ environment\ has\ KOGEN_ACCEPTANCE_FEATURES\ set\ to\ "([^"]*)"$
^the\ recorded\ acceptance\ environment\ has\ KOGEN_ACCEPTANCE_REPORT\ inside\ "([^"]*)"$
^the\ release\ archive\ downloaded\ with\ curl\ and\ installed\ with\ install\.sh$
^the\ release\ archive\ for\ this\ platform,\ extracted\ with\ tar$
^the\ request\ after\ verification\ pass\ (\d+)\ contains\ "([^"]*)"$
^the\ rest\ of\ stdout\ after\ a\ blank\ line\ is\ the\ help\ page\ "([^"]*)"\ from\ chapter\ (\d+)$
^the\ review\ request\ contains\ "([^"]*)"$
^the\ review\ request\ contains\ the\ diff\ of\ "([^"]*)"\ against\ the\ start\ HEAD$
^the\ review\ request\ contains\ the\ full\ text\ of\ the\ committed\ "([^"]*)"$
^the\ review\ request\ contains\ the\ text\ of\ the\ file\ "([^"]*)"$
^the\ review\ request\ does\ not\ contain\ the\ builder's\ conversation,\ tool\ calls\ or\ tool\ results$
^the\ review\ request\ offers\ exactly\ the\ tools\ "([^"]*)"$
^the\ review\ request\ uses\ model\ "([^"]*)"\ with\ effort\ "([^"]*)"$
^the\ run\ log\ shows\ fix\-(\d+)\ once\ before\ verification\ pass\ (\d+)$
^the\ run\ log\ shows\ the\ command\ "([^"]*)"$
^the\ run\ log\ shows\ verification\ pass\ (\d+)\ before\ review\ (\d+)$
^the\ saved\ refresh\ token\ is\ the\ rotated\ one$
^the\ tool\ calls\ ran\ in\ the\ order\ "([^"]*)"$
^the\ tool\ result\ for\ "([^"]*)"\ contains\ "([^"]*)"$
^the\ tool\ result\ for\ "([^"]*)"\ ends\ with\ "([^"]*)"$
^the\ tool\ result\ for\ "([^"]*)"\ is\ "([^"]*)"$
^the\ tool\ result\ for\ "([^"]*)"\ is\ at\ most\ (\d+)\ bytes$
^the\ tool\ result\ for\ "([^"]*)"\ starts\ with\ "([^"]*)"$
^the\ tool\ result\ for\ the\ first\ shell\ call\ contains\ "([^"]*)"$
^the\ working\ tree\ is\ unchanged$
^uname\ reports\ "([^"]*)"\ and\ "([^"]*)"$
^within\ (\d+)\ seconds\ the\ kogen\ command\ has\ exited$
^within\ (\d+)\ seconds\ no\ process\ of\ the\ Build\ command's\ process\ group\ is\ running$
^the working tree has no changes outside the Intent's files$
^the probe ran outside the project folder$
^no probe scratch folder is left behind$
^the installed core shapes "([^\"]*)" through the contracted-deadline driver with stdin:$
^the deadline driver verified the five-minute policy and real timeout cleanup at 200 milliseconds$
^every stdout line so far is protocol output of kogen$
^the new commit is not signed$
^no process started by the Build's commands is running$
^the review request 1 used read_file on "([^"]*)"$
^the new commit changes "([^"]*)"$
^the test build of the core pauses right after creating the commit$
^the core reaches the pause after the commit$
^a broken program "([^"]*)" is first on PATH$
^the run log shows Quint ran with the Node recorded in the installation's node-path file$
^the fake authorization server grants only "([^"]*)"$
```

Verification vocabulary: a green pass means completed fresh setup, acceptance, model and configured checks on exact disposable candidate inputs, with stable scratch inputs and workspace. It never means successful workspace-only commands.

### Fresh Build diagnostic data

`the caller runs {string}` uses the existing command grammar for `intent build
<slug> [--project <checkout>] [--context <file>]`; caller-relative diagnostic files
are data, never stdin or commands. The existing `the exit code is {int}`, `the first
line of stdout is {string}` and `stdout matches {string}` vocabulary checks early
usage failures and rejects the option on non-build paths. Frozen continuation uses
the saved initial conversation, not a replacement context or external file read.

## Prompt reuse evidence

The GPT-7/GPT-9 loopback and local usage scenarios exercise full replay and retained request accounting. The approved prompt-cache usage acceptance vocabulary (`exercise prompt reuse through native`, `retained usage files for prompt reuse`, `run prompt reuse usage with arguments`, `prompt reuse report has`) is implemented in `features/steps/prompt_cache_usage_steps.js`, separately from this chapter harness. Fixtures are guide-shaped synthetic responses, not live account captures.
