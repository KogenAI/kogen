# Changelog

## v0.1.0 (unreleased)

- bbf3fdd Extract the standalone Kogen Loop
- b782019 Verify provider affinity and tool-batch replay
- 84c427d Add caller-owned shell duration bounds (later removed, see below)
- f47ec9f Restore timeout custody liveness
- 0665b58 Explain invalid Anthropic stream outcomes
- 2ea31bf Retry transient provider stream faults
- 3fd0443 Sweep command groups and refuse foreign kills
- 9c079e1 Store a token for the external executor
- bd627aa Keep the provider's bounded refusal message
- c7e8331 Fix two Linux test flakes
- Remove the unused `provider.Request.AnthropicCacheTTL` and `Budget`, `loop.Direct.Policy` (with `ContextPolicy`), `loop.Round.StopAfterTerminal` and `loop.SessionConfig.CacheID` options
- Remove the unused experimental levers: provider prefix-event logging (`provider.Client.PrefixLog`, `EndPrefixLog`, `PrefixEvent`), the read ledger (`loop.Round.ReadLedger`, `ReadLedger`, `NewReadLedger`, `Continuation`), terminal reminders (`loop.Round.TerminalReminders`, `loop.SessionConfig.TerminalReminders`, `loop.Hooks.TerminalReminder`, the `round.terminal_reminder` event), compact tool descriptions (`tools.Tools.CompactDescriptions`) and `tools.Tools.OmitViewImage`. Behavior is fixed at the former defaults: a response without a tool call ends the round, tool descriptions are full and `view_image` is offered whenever it is enabled. No default request, result, definition or tool-output bytes change.
- Remove the optional loop stopping bounds: `loop.Round.MaxRounds`, `loop.RoundLimitError`, `loop.Hooks.Progress`, `loop.NoProgressRounds` and `loop.NoProgressError`. A round ends only by a terminal call, a response without a tool call or an error; defaults are unchanged because zero `MaxRounds` and a nil `Progress` hook already meant neither stop was active. No setting or fixed bound replaces them.
- Remove the climb option levers: `DisableParallelToolCalls` on `provider.Request`, `loop.Request` and `loop.Round`; `provider.Request.AuthorityBoundary`; `InputBudgetBytes` on `loop.Direct` and `loop.FailOverBudget` (with `loop.MinInputBudgetBytes`); `tools.Tools.ResultBound` and `ResultHead` (with `tools.New`, `Tools.Validate` and `Tools.Cut`); and `tools.Documentation.ResultBound` and `BodyBound` (with `Documentation.Validate`). Behavior is fixed at the former defaults: a 524288-byte input window (smaller model-family bounds still apply), a 16384/4096 result cut, a 16384-byte documentation result and 8388608-byte response prefix, provider-default parallel calls and three default cache breakpoints. Defaults are unchanged; no setting replaces the removed options.
- Remove the per-call shell time limit `tools.Tools.ShellTimeout`, with its configured shell description and timed-out feedback. Shell calls behave as they did with the field unset: no per-call time limit, unchanged default definitions and result bytes, and cancellation and deadlines still stop loop-owned shell process groups. `Tools.Definition` remains and returns the default definitions; `sys.Options.Timeout` is unchanged. No setting replaces it.
- Stop every shell at the end of its run: shell calls forward their context (`sys.Session.RunContext`), so cancellation or a deadline covers a shell before, during and after startup and is joined before returning; each round ends the groups it started on success and ordinary failure too, keeping background processes alive only between its calls; and a killed host's supervisor completes whole-group SIGTERM-to-SIGKILL escalation, leaving a keeper for a group that outlives its shell. No option, per-call limit or timeout changes; groups started before the round and detached processes are untouched.
