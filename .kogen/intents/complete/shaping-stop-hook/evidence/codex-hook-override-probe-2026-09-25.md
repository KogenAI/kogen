# Probe: does managed Codex 0.156.1 load hooks from `-c hooks.<Event>=…`? (2026-09-25)

Decision it affects: how the Codex Shaping session gets a Kogen-owned Stop
hook without editing `.codex/hooks.json`. Main's running controller needs that
file, and the Codex compatibility fixture copies it together with a fixed list
of hook scripts (`lib/kogen/codex/compatibility.ex:584-608`), so a new script
referenced from it would be missing in that fixture.

Method (no provider call, no shared scope): a fresh `CODEX_HOME` with no login,
a fresh one-commit git repository as cwd, and the managed binary
`~/Library/Application Support/Kogen/codex/runtimes/0.156.1-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`:

```
CODEX_HOME=<empty> codex exec --skip-git-repo-check --enable hooks \
  --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox \
  -c 'hooks.SessionStart=[{hooks=[{type="command",command="touch <dir>/sessionstart-marker"}]}]' \
  -c 'hooks.Stop=[{hooks=[{type="command",command="touch <dir>/stop-marker"}]}]' \
  --json "say hi"
```

Observed:
- `sessionstart-marker` was created. The hook registered only through `-c`
  ran.
- Codex printed the `--dangerously-bypass-hook-trust` warning twice, once per
  registered hook.
- The turn then failed at the provider (401, no login), so the Stop hook could
  not be reached, and `stop-marker` was not created.
- The binary's strings show `HookEventsToml` with a `Stop` key in the config
  schema, and the Project `.codex/config.toml` help text lists `hooks` among
  its settings.

Conclusion: CLI-override hooks are a supported configuration layer in 0.156.1.
Whether the interactive TUI runs a `-c` Stop hook at the end of each turn, and
continues when it returns `{"decision":"block"}`, is a provider-only
observation. This Intent's `live-shaping-quality` run covers it (seven real
Codex Shaping sessions launched with the hook). Kogen's Developer Stop hook
already relies on the same `block` semantics under `codex exec`.

Limits: exec, not the TUI. SessionStart, not Stop.
