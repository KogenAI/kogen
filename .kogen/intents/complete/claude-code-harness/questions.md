# Questions and settled decisions: Claude Code harness

Approved by the Shaper on 2026-09-23T05:19:09Z; see evidence/approval.md.

## Settled by the Shaper (23 September 2026)

- Use Claude Code with Opus 5.5 to drive Kogen for the next few days; switch to
  ChatGPT later. Claude Code must be "almost plug-n-play" so switching is cheap.
- Keep Codex as an adapter for now: its offline tests keep running (a test of
  the adapter pattern); paid targets run only for the configured harness.
- Kogen manages the harness runtime completely, including versions: only tested
  pins, no self-update, Kogen-owned logins separate from personal tools, no
  carry-over of personal credentials.
- The proven-model list is a model picker, not a per-request filter.
- Build: manual in Claude Code following the Kogen flow, one commit; message
  body "Built by Claude Opus 5.5 in Claude Code, outside the regular Kogen flow
  because ChatGPT tokens ran out, following Kogen's instructions."

## Shaper decisions (23 September, continued)

- Harness name is `claude` (matching `mix kogen.claude.*` and the `claude` executable).
- Helper models stay global; each role's helpers get only that role's authority
  (Reviewer and Shaper helpers are read-only).
- Haiku 4.5 is not on the proven list; Sonnet 5 at low is the scout.
- Opus 5.5 runs at medium (Anthropic's default, and this session's) for
  shaping, developer and reviewer; only the expert runs at high.
- The Shaper's first Kogen login (at `.../Kogen/claude-code/...`) may be moved or
  redone: "Move if you have to. I can log in again." Root logged it out.

- Every Kogen claude invocation uses --dangerously-skip-permissions (no
  permission prompts, no sandbox), including interactive Shaping and login.
- mix kogen.claude.login opens the interactive claude so the Shaper completes
  Claude Code's own first-run flow; per-project login does the same in the
  project's config dir.
- Per-helper effort is kept (undocumented but observed in the pinned version).
- API (Console) login is not used for now; offline-tested only.

## Decisions from research (23 September)

- The Developer does not use --json-schema; the Stop hook works as documented,
  like Codex. The Reviewer keeps --json-schema. (A Stop-hook block after
  StructuredOutput is undocumented and ignored; the nearest GitHub report,
  #86569, is the same bug for subagents, closed as not planned.)
- Folder trust: users trust their own repositories once. The live Shape test
  pre-trusts only its own fixture repo through the documented
  hasTrustDialogAccepted setting and removes the entry afterwards. Kogen never
  answers the trust dialog.

## Engineering choices made in Shaping (no human decision needed)

- The verification catalog stays byte-identical: `live-native` remains Codex's
  native target (unselected); Claude Code is proven through the harness-neutral
  paid targets `live-general`, `live-reviewer-rework`, `live-shape-to-build`,
  with Claude Code assertions added inside their owner tests.
- Hook scripts stay in `.codex/hooks/` and are registered for Claude Code
  through a Kogen settings file (same hook protocol); renaming them is a later
  cleanup.
- Pin Claude Code 2.1.280 (the version this Shaping and the prior manual Build
  ran on); npm stable is 2.1.267.

## Build prerequisite (Shaper)

Done 23 September: the Shaper logged the shared scope in at its final path
(`claude auth status`: loggedIn, authMethod claude.ai, subscriptionType max), and a
root request from that scope with `--setting-sources project --strict-mcp-config`
succeeded on `claude-sonnet-5` with `mcp_servers: []` and `apiKeySource: none`.
The command, for reference:

```sh
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Kogen/claude/accounts/shared" claude auth login
```

## Non-goals

Any harness other than codex and claude, removing Codex, hosted Shaping, renaming
`.codex/hooks`, Windows/Linux acceptance.
