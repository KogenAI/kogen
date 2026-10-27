# Pass the stored Claude Code token on fd 3

Slug: ktoken2-token-fd
Model: not applicable — a change of how one credential reaches a child process; no state machine
Acceptance:
- .kogen/intents/ktoken2-token-fd/acceptance.feature
- features/steps/ktoken2_token_fd_steps.js
- features/steps/ktoken2_observe.js

With Claude Code 2.1.310, setting `CLAUDE_CODE_OAUTH_TOKEN` together with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` makes the init event report permission mode `default`, so the shape stops with `executor/protocol: Claude Code reports permission mode "default", not acceptEdits`. A token on a pipe via `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3` (no scrub) reports acceptEdits and the token is used.

Change `cli/executor/claudecode`: when a stored token is given (`Options.Token`), every Claude Code child that gets the token (the `claude auth status --json` preflight, the first round and every `--resume` round) receives it on an inherited pipe at fd 3 (`ExtraFiles`) and `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3` in its env. Each such child gets a fresh pipe: Kogen writes the token (exactly, no added newline), closes the write end, starts the child, then closes its own copy of the read end (also when the start fails). The auth-status preflight needs the token, so it gets the same pipe; this is a decision, not a new feature.

The child env never sets `CLAUDE_CODE_OAUTH_TOKEN` or `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` (remove the code that sets them). Both stay on `stripEnv` (inherited values are removed), and `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` and `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` are added to it. Redaction of the token in records stays. With no stored token behaviour is exactly as today: no fd 3, no FILE_DESCRIPTOR variable. The acceptEdits check is unchanged; no new timeout, retry or limit. Update the Go tests that assert the old env (`adapter_test.go` childEnv/scrub expectations, and `fake_test.go` fakes that read `CLAUDE_CODE_OAUTH_TOKEN`, which must read fd 3 instead) and the docs that describe the old env (`README.md`, `docs/configuration.md`, `docs/executor-contract.md`, `spec/prose/04-building.md` LOOP-15) to say the token goes on fd 3. The older Intent `k-token-stored-login` asserts the old env in its acceptance (and its shim reads the env token); that part is superseded by this Intent. The Build must keep the configured checks green and must not edit that Intent's protected files.

## Decisions
- Token on an inherited pipe at fd 3 with `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`, fresh per child, write end closed, Kogen's read end closed after start (source: request)
- `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` never set; both plus the two FILE_DESCRIPTOR variables stripped from inherited env (source: request)
- The auth-status preflight also gets the token on fd 3, since the token is no longer in the env (source: request)

## Source comparison
- Pipe on fd 3 via ExtraFiles, write, close write end, close read end after start: addressed (intent prose; scenario 1).
- Do not set OAUTH_TOKEN / SCRUB; keep both stripped; add the two FILE_DESCRIPTOR names to the strip list: addressed (scenarios 1-3 check env and inherited values).
- Fresh pipe every round, first and --resume: addressed (scenario 1 requires a first and a --resume round, each reading the whole token from fd 3).
- Redaction stays; no token in argv, env or records: addressed (observer checks env/argv; scenario 1 scans files).
- No stored token = today's behaviour; no fd 3 and no FILE_DESCRIPTOR variable: addressed (scenario 3).
- acceptEdits check, no new timeout/retry/limit: unchanged, not touched.
- Inherited OAUTH_TOKEN, SCRUB and both FILE_DESCRIPTOR variables not passed: addressed (scenarios 2 and 3; inherited FD values are 9, so only Kogen's `3` passes).
- All configured checks pass: required of the Build.
- Superseded: k-token-stored-login's assertion that the child env holds CLAUDE_CODE_OAUTH_TOKEN, and its docs wording.
- Host safety (synthetic tokens, no real claude, no process-name kills): the fixture uses a synthetic token and a shell shim only.

## Tests
- Stored token on fd 3 with FILE_DESCRIPTOR=3, no OAUTH_TOKEN/SCRUB, exactly the token, first and --resume round and auth preflight: scenario through the real `kogen intent shape` and a recording claude shim (scenario)
- Inherited OAUTH_TOKEN, SCRUB and both FILE_DESCRIPTOR variables not passed: scenarios 2 and 3 (scenario)
- No stored token gives no fd 3 and no FILE_DESCRIPTOR variable: scenario 3 (scenario)
- childEnv and the round/auth start code: update the Go unit tests in `cli/executor/claudecode` for the fd 3 pipe, the strip list and a fresh pipe per round (unit)
- Redaction of the token in records stays: existing redaction tests, with fakes reading fd 3 (existing)

## Feasibility
- evidence: {"id":"observer","kind":"observer","inputs":["features/steps/ktoken2_control.cjs","features/steps/ktoken2_observe.js"],"observers":["features/steps/ktoken2_observe.js"],"checks":[{"name":"good","command":"node features/steps/ktoken2_control.cjs good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/ktoken2_control.cjs bad","exit":1,"output":"rejected\n"}]}
- Probe: one `kogen intent shape` with a shaper output naming another slug makes Kogen send feedback in `--resume` rounds of the same session (auth status, one first `-p`, then two `-p --resume`), so the --resume round is reachable deterministically. (probe 3: exit 0, 38 s)
