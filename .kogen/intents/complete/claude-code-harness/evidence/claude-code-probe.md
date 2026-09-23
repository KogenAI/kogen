# Probe: Kogen's harness contract on Claude Code 2.1.280

23 September 2026, root Shaping probe; disposable repo `/tmp/kogen-cc-probe/work`,
`claude-sonnet-5` root and `claude-haiku-4-5-20251001` helper, Shaper's
subscription. Retained: settings.json, stop.sh, pre.sh, turn summaries (raw
streams not retained; they contain model reasoning).

- `CLAUDE_CONFIG_DIR=<empty dir> claude auth status` -> `loggedIn: false,
  authMethod: none`; default -> `loggedIn: true, authMethod: claude.ai`.
  Status is metadata-only JSON. `claude auth login` offers `--claudeai`
  (subscription, default) and `--console` (API billing).
- npm `@anthropic-ai/claude-code@2.1.280` ships per-platform native binaries as
  optional dependencies (same shape as `@openai/codex`). darwin-arm64 integrity
  `sha512-ctkNgja8Yi2kngVFPO2667k6zbtJwjQ+dOTeEp1XmzHcoDFdaee4h4WVgZllsewm/Io+pPPPSFQVdGHOtdE/1A==`,
  darwin-x64 `sha512-991qNyZVC/ra6THRMLDJ1mB1a+/C/bpKEA1w5ttNJA0mTvVm012kAbS3Pf7zrvRBFe7fU1KeHkGlTTq49519qA==`.
- Turn 1 (`claude -p --session-id <uuid> --settings ... --setting-sources project
  --agents {scout: haiku, read-only} --output-format stream-json`): session id
  honored; PreToolUse denied `make check` and the reason reached the model; the
  scout ran on Haiku (helper messages linked by parent_tool_use_id; result
  modelUsage lists both models); the Stop hook's `{"decision":"block"}` continued
  the same turn with its reason.
- Turn 2 (new process, `--resume <uuid> --json-schema`): same session; recalled the
  blocked reason exactly; `structured_output` matched the schema.
- An earlier manual Kogen Build (22 September) already ran Kogen's Developer (exact resume) and
  Reviewer (`--json-schema` verdict) roles on `claude-opus-5-5` and Kogen's
  unchanged `verification_policy.py` as a Claude Code PreToolUse hook.

Limits: one host, few requests; the managed install, Kogen scope login and
interactive Shaping TUI are proven by the Build's paid targets.

Addendum (same day): after the Shaper logged a Kogen scope in, renaming the scope
directory made `claude auth status` report `loggedIn: false`; renaming it back
restored `claude.ai`. The Keychain holds `Claude Code-credentials-<hash>` per
config dir, so scope paths must be stable. The logged-in scope also contained
Claude Code's cached account connectors (`plugins/`, `mcp-needs-auth-cache.json`),
which is why roles need `--strict-mcp-config`.

Addendum 2: from the logged-in Kogen shared scope (`subscriptionType: max`),
`claude -p --model claude-sonnet-5 --effort low --setting-sources project
--strict-mcp-config` with provider variables unset returned `OK`; init reported
`mcp_servers: []` and `apiKeySource: none` (subscription OAuth). Init also listed
Claude Code's built-in agents (`claude`, `Explore`, `general-purpose`, `Plan`),
which a role could use to delegate on its own model; Kogen must make them
unavailable so delegation goes only through its configured helpers.

## Addendum 3: assumption probes before approval (23 September)

Proven: pinned darwin-arm64 2.1.280 package integrity equals the pin and the
extracted binary runs from any folder; with DISABLE_AUTOUPDATER=1 a request left
its hash unchanged and installed nothing into ~/.local/share/claude; resuming a
missing session exits 1 ("No conversation found"); Kogen's real handoff schema
works with --json-schema (bound token, valid distinct scenario ids, all risks);
`--disallowedTools Agent(<name>)` denies built-in agents under bypass while
custom agents run; read-only helper tools prevent writes; Bash PreToolUse hooks
apply inside helpers (hook input carries agent_type); helpers fire SubagentStop,
not Stop; KOGEN_ROLE reaches hooks (Shaper-run probe).

Finding: a Stop-hook block is ignored when the model ends with StructuredOutput
(reproduced with and without helpers); a PreToolUse hook on StructuredOutput is
honored (denial delivered, model resubmits with the fix). A PreToolUse
`continue:false` stops the turn (`terminal_reason: hook_stopped`) but the result
still carries `structured_output` (Shaper-run probe), so Kogen must not treat it
as an accepted handoff.

Interactive: a fresh config dir shows first-run screens (theme, login) that
`claude auth login` does not complete; the Shaper completed them interactively.
Every new folder then shows a trust dialog (default "No, exit") even with
--dangerously-skip-permissions; after trusting, the first message ran and
replied PONG with no other screens (Shaper-run). No documented setting skips
trust or onboarding. Automating the trust answer was deliberately not done.

Per-helper effort: `--agents {"scout":{..., "effort":"high"}}` with root
`--effort low` recorded `"effort":"high"` in the helper transcript and `"low"` in
the root transcript. Official docs list no effort field for subagents and call
the transcript format internal, so this is undocumented pinned-version behavior.

Not testable here: Anthropic Console (API billing) login; offline tests only.

## Addendum 4: documentation research (23 September)

Documented (code.claude.com/docs/en/permissions): the trust dialog appears only
in interactive sessions; `-p` and SDK sessions never show it; trust is keyed on
the git repository root and does not cover nested repositories (changelog
2.1.232); a folder may be trusted by hand with
`projects["<path>"].hasTrustDialogAccepted = true` in the config JSON. No flag,
setting, env var or policy disables the dialog. Structured output: the Stop-hook
interaction observed in Addendum 3 is undocumented; GitHub #86569 reports the
same for SubagentStop with a schema (reproduced, closed as not planned);
StructuredOutput is not a documented hook matcher; a success result without
structured_output must be treated as a failure (agent-sdk/structured-outputs).
