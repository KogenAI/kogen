# Run the live real-use test on the Claude route

Slug: k-live-real-use-claude
Model: not applicable — a sequential shell script whose checks run once in a fixed order, with no interacting state
Acceptance:
- .kogen/intents/k-live-real-use-claude/acceptance.feature
- features/steps/k-live-real-use-claude__real_use.js

`test/live/real-use.sh` (REL-1) proves the whole new-user path on a fresh home for the route the run home's login selects. It covers (a) Claude Code only, where a seat's Claude Code token arrives through `KOGEN_LIVE_CREDENTIALS`, and (b) ChatGPT. Today the script only knows ChatGPT. It always checks `chatgpt: signed in`, reads `~/.kogen/credentials/chatgpt.json` in its leak and intact checks, and cannot pass with only a claude-code login. After this change, route (a) runs install, `kogen init`, `kogen intent shape`, approve, an interrupted Build, a landed Build, verification without Kogen, the leak check and uninstall. Each step reads the lineup `kogen init` committed in `.kogen/models.yaml`, and no ChatGPT login hint appears in the transcript or the command outputs. Route (b) keeps working exactly as before, now with a lineup check too.

The product already does what this route needs. `kogen init` with only a claude-code token selects claude-code, writes `executor: claude-code` for shape, build and review into `.kogen/models.yaml`, and installs Kogen's managed Claude Code 2.1.312 through its first Claude Code role. The pinned coordinator's `LoadConfig` applies `.kogen/models.yaml` (the adopted c-load-config-applies-models-file fix), so shape, build and review run on that lineup. So no Go code, Kogen CLI command or flag changes. "Claude Code 2.1.312 not installed" right after login is the intended managed-runtime behaviour, because nothing downloads at login or list. The runtime check therefore follows `kogen init`.

### Changes to `test/live/real-use.sh`
The usage stays `sh test/live/real-use.sh <project> <archive-url>`, with the same project settings contract (REPO, SLUG, REQUEST, configure(), verify_without_kogen(), optional INTERRUPT_AFTER), `KOGEN_LIVE_RUN_DIR`, `KOGEN_LIVE_CREDENTIALS` and `say`/`check`/`fail` transcript format (`<UTC time> <text>`, stop at the first failed check with `FAIL: <message>` and exit 1). Every message below is printed exactly, after the time.

1. **Step 2, route.** Credentials are written as today: the `KOGEN_LIVE_CREDENTIALS` command, or without it the browser login `kogen provider login chatgpt` (unchanged). Then the script reads `kogen provider list`. The route is `claude-code` when the list has the line `claude-code: token saved (not verified)` and no line starting with `chatgpt: signed in`. Otherwise the route is `chatgpt`. It says `route: <route>`. On claude-code it checks that list line, with the message `kogen provider list shows claude-code: token saved (not verified)`. On chatgpt the existing check and message `kogen provider list shows chatgpt: signed in` are unchanged.
2. **Step 3, lineup.** Right after `kogen init`, the script checks the `.kogen/models.yaml` that init wrote. On claude-code, each of the roles shape, build and review must have `executor: claude-code` and no `provider:`. On chatgpt, each must have `provider: chatgpt` and no executor other than native. The message is `.kogen/models.yaml from kogen init runs shape, build and review on <route>`.
3. **Step 3, runtime (claude-code only).** Still after init, `kogen provider list` must have the line `claude-code runtime: Claude Code <version> installed (<run home>/.kogen/claude-code/<version>/claude)`, and that path must be an executable file. The message is `the managed Claude Code runtime is installed in the run home`. The version is read from the line, not hard-coded.
4. **Step 7, model work.** On chatgpt the existing `"event":"tool_call"` check and message are unchanged. On claude-code, the landed run's `.kogen/local/runs/<run>/log.jsonl` must have an `"event":"executor_round"` event of executor `claude-code`. Claude Code's tool calls are not Kogen `tool_call` events. The message is `at least one Claude Code round ran in the Build`.
5. **Step 9, leak.** The secrets are the route's credential: on claude-code, the `api_key` value of `$HOME/.kogen/credentials/claude-code.json`; on chatgpt, `access_token` and `refresh_token` of `chatgpt.json` (unchanged). The scan, `leak.txt` and the message stay the same. The scan covers regular files directly in the run folder plus every file of the project outside `.git`. `leak.txt` lists each leaking file's path, one per line (`<run folder>/transcript.txt`, `<run folder>/project/<path>`). The failure is `FAIL: no credential token in the project, .kogen/local, the transcript or the command outputs` with exit 1. On claude-code only, right after the leak check, no regular file directly in the run folder (the transcript and command outputs) may contain `provider login chatgpt`. The message is `no ChatGPT login hint in the transcript or the command outputs`.
6. **Step 10, intact.** The credential that must still exist is `$HOME/.kogen/credentials/<route>.json`. The message `the project and ~/.kogen are intact` is unchanged.

Every other step, check and message stays unchanged: install, the interrupted Build (exit 130 within 15 s, no new commit, discard the listed edits), commit subject/trailer/attribution/signature checks, `no Kogen process is alive`, uninstall, and `REL-1 passed for <project>`. The header comment documents both routes and the unattended Claude Code form, for example `KOGEN_LIVE_CREDENTIALS='kogen provider login claude-code < <token file>'`.

### Documents
In `spec/prose/11-release-acceptance.md`, REL-1 steps 2, 7, 9 and 10 describe both routes as above. `docs/contributing.md` gains the unattended Claude Code route command next to the existing real-use lines. The `@live` feature `spec/features/11-release-acceptance.feature` keeps its step sentences.

### Offline acceptance
The scenarios run the candidate `test/live/real-use.sh` itself, end to end on a fresh home, with:
- the release archive the configured setup packaged (`file://`);
- the py-calc fixture as the project, with Intent `is-even` and title "Add an is-even helper";
- a fake ChatGPT server from `test/acceptance/support/fake-servers.js` on `KOGEN_PROVIDER_URL` on both routes, which on route (a) must receive no request;
- the repository's fake Claude Code (`test/acceptance/fixtures/claude/fake-claude.js`), served as the managed runtime through the loopback `KOGEN_CLAUDE_CODE_URL`.

The first Build's model turn is held so the script's SIGINT finds a Build in progress. These fixtures and `test/acceptance/fixtures/projects/py-calc` stay unchanged. A live run with a real seat token stays the operator's release gate: no paid or live call here.

## Decisions
- The route is the login the run home has after step 2: a claude-code token without a ChatGPT login means the Claude Code route; anything else keeps the ChatGPT route, including the unchanged browser login. (source: request)
- A seat's Claude Code login is given only through `KOGEN_LIVE_CREDENTIALS`; no Kogen CLI flag is added. (source: request)
- Each route reads and checks the lineup `kogen init` wrote in `.kogen/models.yaml`; on the Claude Code route no ChatGPT login hint may appear in the transcript or command outputs, including init's final readiness lines. (source: request)
- The managed runtime check follows `kogen init`, the first Claude Code role, which installs it. (source: request)
- The fix changes only test/live/real-use.sh and its documents. No Go code, Kogen CLI command or flag changes. (decision: D1, round 1) (constraint: No new kogen CLI flag or command) (constraint: The 'not installed' runtime line right after login is intended; the runtime check follows kogen init) (evidence: test/live/real-use.sh; cli/readiness/readiness.go; cli/native.go) (assumption: Pinned kogen-setup init selecting claude-code and installing the runtime is supported only by reading module-cache sources outside HEAD and a host-shell scratch run, not by a Kogen probe record.) (source: request)
- real-use.sh picks its route from `kogen provider list` after step 2. The route is claude-code when the list has 'claude-code: token saved (not verified)' and no 'chatgpt: signed in'; otherwise chatgpt, unchanged. (decision: D2, round 1) (constraint: The leak secret on claude-code is api_key of ~/.kogen/credentials/claude-code.json) (constraint: The intact check uses ~/.kogen/credentials/<route>.json) (evidence: cli/third_party/kogen-loop/provider/creds.go; cli/third_party/kogen-loop/provider/keys.go) (source: request)
- On the claude-code route, the step-7 model-work check reads executor_round events of executor claude-code, not tool_call events. (decision: D3, round 1) (assumption: Grounded in reading pinned kogen-build sources in the module cache (outside HEAD) and a host-shell scratch Build whose log.jsonl held executor_round events with executor claude-code; there is no Kogen probe record.) (source: request)
- Acceptance runs the candidate real-use.sh offline on four scenarios: claude-code route, ChatGPT route, and two leak runs. (decision: D4, round 1) (evidence: test/acceptance/support/fake-servers.js; test/acceptance/fixtures/claude/fake-claude.js; test/acceptance/fixtures/projects/py-calc/README.md) (assumption: Not yet observed: the candidate script on route (a), and the held-turn interrupt on either route. The unchanged script stops at its chatgpt login check, so readiness shows red there.) (source: request)

## Source comparison
- addressed: real-use.sh runs end to end on the claude-code route with a login given through KOGEN_LIVE_CREDENTIALS: changes 1-6; scenario 1.
- addressed: init, shape, build and review use the Claude lineup from the models file `kogen init` writes; no CLI flag beyond the agreed CLI: change 2; scenario 1 checks the landed `.kogen/models.yaml` and that the fake Claude Code served init, shape, build and review.
- addressed: the managed Claude Code runtime is installed in the run home: change 3; scenario 1 (download origin served the runtime once).
- addressed: the login, leak and intact checks cover the claude-code credential: changes 1, 5, 6; scenarios 1 and 3.
- addressed: with only a claude-code credential, real-use.sh passes all its checks and no ChatGPT request is made (fake-server and transcript check): scenario 1.
- addressed: the leak check fails when the claude-code token appears in the project or transcript: change 5; scenario 3 (both examples).
- addressed: delivery note, both routes on a fresh home: install the release, `kogen init`, `kogen intent shape`, approve, build, and the Build lands a commit; (b) ChatGPT on a fake ChatGPT server since live ChatGPT is off: scenarios 1 and 2.
- addressed: delivery note, each step reads init's lineup and on route (a) no ChatGPT request or login hint appears anywhere, including init's final readiness line: changes 2 and 5; scenario 1 (fake server received nothing; no `provider login chatgpt` in the transcript or command outputs).
- addressed: all configured checks pass: Kogen's normal verification.
- superseded: "kogen init asks its model before any project config exists, so a fresh run home uses ChatGPT" (diagnosed row). The pinned kogen-setup now selects the only signed-in route; observed in a shaping probe as `kogen: selected claude-code for discovery and shape, build and review`.
- superseded: REL-1 prose naming only `kogen provider login chatgpt`, `chatgpt: signed in` and `chatgpt.json`: documents section.
- prerequisite present: c-load-config-applies-models-file (LoadConfig applies `.kogen/models.yaml`) is in the pinned kogen-coordinator (`project/config.go` applyFiles).
- omitted: a live run with a real seat token or ChatGPT account in this Intent's acceptance. It is the operator's release gate; ChatGPT is off for live use by owner order.
- addressed: host safety. Runs use temporary directories; the only process group ever signalled is the one the step started, and only at its 25-minute watchdog; no synthetic CPU load.

## Tests
- The route follows the run home's login and the claude-code login is checked: scenario 1 (scenario)
- init's lineup in `.kogen/models.yaml` is checked on both routes: scenarios 1 and 2 (scenario)
- The managed runtime is installed after init: scenario 1 (scenario)
- The claude-code Build's model work is checked through its executor_round event: scenario 1 (scenario)
- The leak check uses the claude-code token and fails when it is in the transcript or the project: scenario 3 (regression)
- No ChatGPT request and no ChatGPT login hint on the claude-code route: scenario 1 (scenario)
- The intact check uses the route's credential file: scenarios 1 and 2 (scenario)
- The ChatGPT route still passes end to end against a fake ChatGPT server: scenario 2 (scenario)
- verify_project and run_logged failure propagation stay unchanged: test/live/check-verify.sh in the deterministic suite (existing)

## Feasibility
- evidence: {"id":"real-use-observers","kind":"observer","inputs":["features/steps/k-live-real-use-claude__real_use.js"],"observers":["features/steps/k-live-real-use-claude__real_use.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k-live-real-use-claude__real_use.js control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k-live-real-use-claude__real_use.js control bad","exit":1,"output":"rejected\n"}]}
- Observed in a shaping scratch run, outside the checkout, of the packaged 47236bbb archive (host shell observation, not a Kogen probe record). With only a claude-code token and this fake Claude Code served through `KOGEN_CLAUDE_CODE_URL`, `kogen init` on py-calc did the following:
  - printed `kogen: selected claude-code for discovery and shape, build and review`;
  - installed Claude Code 2.1.312 with exactly the requests `/2.1.312/manifest.json` and `/2.1.312/darwin-arm64/claude`;
  - wrote shape/build/review `executor: claude-code` (`claude-sonnet-5-5`, efforts high/medium/high);
  - ended with `ok models - shape, build, review ready`, with no ChatGPT hint;
  - made `kogen provider list` print `claude-code runtime: Claude Code 2.1.312 installed (<home>/.kogen/claude-code/2.1.312/claude)`.
- In the same scratch run, `kogen intent shape is-even` printed `Scenarios: 3 (3 fail now, 0 pass now)`. Approval and `kogen intent build is-even` landed "Add an is-even helper" with the only trailer `Kogen-Intent: is-even` and `review: approved`. The run log held `"event":"executor_round"` events with `"executor":"claude-code"`. (host shell observation)
- Not observed: route (a) inside the candidate script and the held-turn interrupt on either route. The unchanged script stops at its `chatgpt: signed in` check on route (a), so readiness shows missing-feature red there.
