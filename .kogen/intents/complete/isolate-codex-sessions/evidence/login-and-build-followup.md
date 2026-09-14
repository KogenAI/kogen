# Login and failed Build follow-up

Visit: 2026-09-10T09:50:00.754357Z. Source: Shaper supplied a login screenshot
and failed Build diagnostic in this conversation; read-only local investigation.

The Shaper reports that the current changes come after another failed Build.
This supersedes the opening uncertainty about whether any new Build occurred;
it does not establish acceptance or authorize discarding/restoring the changes.

The installed managed 0.154.0 runtime's `login --help` exposes `--with-api-key`
(read from stdin), `--with-access-token`, and `--device-auth`. Only help was run:
no real credentials were inspected, no login or model call was made.
`lib/kogen/codex.ex` login_arguments/1 forwards arguments after `--`, and
terminal/2 delegates native stdio. Existing public-task tests contain a synthetic
PTY/stdin case; no tests were run in this shaping visit.

Official documentation fetched 2026-09-10:
https://learn.chatgpt.com/docs/auth
It describes default browser ChatGPT login and native API-key login via stdin.
ChatGPT workspace controls and API organization controls are distinct; API use
is billed through Platform. Browser login is not proof of personal-only use.

Recommended clarification, pending Shaper choice: retain native delegation and
explain both methods in help/docs. Shared API-key command, with the key already
available in the caller environment:

```sh
printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key
```

For project scope add `--project` before the forwarding separator. This is native
Codex's flag, not a new Kogen authentication implementation. No real-key login
through the unfinished wrapper was performed during this visit.

## Build record findings

Read-only configured worker investigation of
`.kogen/runtime/scenario-tracking/hIhZhNA3cELjirafTGGRSVMc/record.json`:
all three attempts passed their Stop-owned Check. The first submitted a valid
all-ready handoff, then failed live (exit 2). Both resumptions supplied all twelve
IDs with incomplete statuses; neither reached live or independent Review.
The final handoff marked nine scenarios incomplete (corrected after detailed inspection).
No accepting Review exists.

The Developer prompt permits ready/incomplete (`priv/kogen/prompts/developer.md:167`),
while acceptance validation requires ready (`lib/kogen/build/contract.ex:198-203`).
The generic exact-coverage error lists every expected ID if any entry fails
(`contract.ex:349-357`), obscuring the actual incomplete subset. This is not proof
that all IDs were missing or that relabeling unfinished work would satisfy the
Intent. Preserve the requirement that incomplete work cannot earn acceptance.
The earlier MCP, patch and hook errors are not the terminal stopping condition;
the source of MCP discovery has not been established by this investigation.

The retained live-output tail reports six failed tests and specifically
`test/kogen/codex_native_live_test.exs:27-28`: installed() returned the missing
managed-runtime error. Other probe exits appear without their complete root
assertions. The final handoff left native authenticated setup/acceptance unproven
for nine scenarios; only install, install-failure-preservation and status were
claimed ready. The Shaper screenshot now demonstrates subsequent installation
and an attempted browser login, but does not show successful login completion.

Pending shaping issue: establish how the live gate obtains its explicitly
installed/authenticated managed runtime before another Build, while preserving
no automatic install/login by managed roles and no personal credential fallback.
No change to that public setup policy is accepted in this visit.

## Bootstrap explanation, follow-up inspection

`test/kogen/codex_native_live_test.exs:28` assumes installed(); the private
installer test creates and cleans its own temporary runtime, which does not
provision the persistent user installation. `codex_compatibility_test.exs` also
requires installed(), effective_scope(), and require_login() before native runs.
`lib/kogen/codex.ex` management_allowed!/1 rejects public setup for managed roles.
The accepted Intent requires explicit user login and forbids personal credential
imports. Thus implementation work alone could not satisfy these external live
prerequisites. Both resumed handoffs explicitly reported this blocker.
No new tests, login, installation or implementation edits were performed here.

Official device auth documentation fetched again during this follow-up:
https://learn.chatgpt.com/docs/auth (Login on headless devices).
It requires the user to open a link and enter a code, and may require account or
workspace enablement. Native `--device-auth` is a forwarding example, not an
unattended API-key alternative.
