# Contract suite

`contract/` is a Go test package of the `kogen-loop` module. It pins what kogen-loop's consumers use: the exported API of `api`, `loop`, `provider`, `sys` and `tools` that they call, the behaviours they rely on, and the file and wire formats they read or write. The consumers are kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review and kogen-build.

The suite runs in kogen-loop's own fast gate (`go test ./...`, the configured `go-test` check), so an interface change fails here first and the consumers' offline suites do not have to run at every landing. An intended interface change edits this contract together with paired consumer items.

## What it is

- Every test is a `_test.go` file of the package `contract_test`; `doc.go` only names the package. No file has a build constraint, so `go test ./...` runs the suite on every platform.
- The cases are copied and adapted from the consumers' own tests, or from the consumer code that uses a member when no consumer test exercises it. Each test's comment names the consumer files it was adapted from.
- The fixtures are synthetic: loopback `httptest` servers, `t.TempDir()` roots, Git repositories and `HOME` directories, fake tokens, `example.invalid` addresses, and explicit `sys.NewWith` environments with their own Git identity and `GIT_CONFIG_GLOBAL=/dev/null`.
- It runs no model, contacts no non-loopback host, relies on none of the caller's `HOME`, credentials or `KOGEN_*` variables, reads none of kogen-loop's source files and imports no consumer module.
- It is fast: no test waits on a real 45-second shell yield, a 5-second termination wait, a provider backoff or a retry sleep. It uses the seams the consumers use (`Client.Now`, `Client.Sleep`, short commands), has no `t.Skip`, and uses no fixed port or shared path.
- Commands run under the supervisor (`sys.EnableSupervisor`), so `TestMain` calls `sys.MaybeSupervise(os.Args[1:])` first, as `sys/sys_test.go` does.

Run it with `go test ./contract/...`, or as part of `go test ./...`.

## Sources

The first 226 members were derived mechanically with a go/types observer over each consumer's Go module, tests included, at these `main` commits:

- kogen `9bf6073f8096f5a50013fc42c482695742645ac8` (`cli/`, against its vendored `cli/third_party/kogen-loop`, plus the migration drivers under `test/migration/drivers/` that compile)
- kogen-coordinator `0ad33f64273515844c2980a432b1a4219b8e68bb`
- kogen-executor `bcb2c76ad20c1f6004bd6f37447560f6114f5bd7`
- kogen-verification `f39e7c2c62fdde97d77d23366238fa9562e65cce`
- kogen-shaping `f561b3df6f00507ebc7249857f0662736a1769d0`
- kogen-build `1a8a18d75c1f5ecf8aa057c49551a9a98c342d7c`

The inventory was then derived again with the same observer at the commits of the eight current consumers (kogen-setup and kogen-review now use kogen-loop too):

- kogen `a1a04454a891a8a8b823d5cdba5c77ab0301cc28` (`cli/`, against its vendored `cli/third_party/kogen-loop`, plus the migration drivers under `test/migration/drivers/` that compile)
- kogen-coordinator `e26a4d75cdcc3bbcd6d900f2698cac8144bfdc19`
- kogen-executor `923b1adfa45cbed0c5a0722a1da1bd975b4409e5`
- kogen-verification `f4d004d53a8d2928c778462944993a93fc5f5ee4`
- kogen-shaping `b350d99e012f313f36693d6ee6613f38aea14808`
- kogen-setup `8ee693982160de909fa326a41c9bfcdf3e26ef74`
- kogen-review `3e1f93f3de911cd737832dbccc626b026a6bd072`
- kogen-build `6c012108c6faa4ea7814c76a360d3ab31d365b1c`

The consumers other than kogen resolve kogen-loop at `c6e2360`. The 232 exported members of `kogen-loop/api`, `loop`, `provider`, `sys` and `tools` they use are listed below; every one is used by the suite's Go code in a real case (a call whose result is asserted, a field set or read in such a call, a type constructed or received, a constant's or variable's value asserted), not a bare reference. A row's "Derived from" paths are consumer sources at the original commits or, where the original consumer no longer uses the member, at the current ones.

## Consumed Kogen repositories

kogen-loop depends on no other Kogen repository, so it has no consumes/ directory.

This was checked three ways: `go.mod` has no `require` directive and there is no `go.sum`; `go list -m all` lists only `kogen-loop`; and `go list -deps -test ./...` lists only standard-library packages and kogen-loop's own packages, so no non-test or test code imports an identifier of another Kogen repository.

The consumers state their uses of kogen-loop in their own `consumes/kogen-loop/` suites, which this contract must cover.

## Behaviours and formats

Each is asserted so that changing it fails the suite:

- `sys-error-line`: `(*sys.Error).Error()` is `<class>/<reason>: <detail>` and `Render()` adds `\n` (`TestErrorLine`).
- `sys-error-lines`: `Render()` prints each of `Lines` indented by two spaces and ending in `\n` (`TestErrorRenderLines`).
- `sys-interrupt-exit`: `(*sys.Interrupted).ExitCode()` is 130 for `SIGINT`, 143 for `SIGTERM` and 129 for `SIGHUP` (`TestInterruptedExitCodes`).
- `sys-foreign-kill-status`: `Session.Run("pkill -f x", dir, sys.Options{RefuseForeignKill: true})` starts nothing and returns status 126, the refusal text and the rule `pkill-killall` with a nil error (`TestRunRefusesAForeignKill`).
- `tools-unknown-tool`: `Tools.Run` of a name that is not enabled returns `error: unknown tool <name>` (`TestToolsRefuseNamesThatAreNotEnabled`).
- `tools-read-numbered`: `read_file` numbers lines as `<n>\t<line>` (`TestToolsReadFileNumbersLines`).
- `tools-cut-bound`, `tools-cut-head`: a 30000-byte shell output cut by `Output.Cut()` or `tools.Cut` is exactly 16384 bytes, its marker `\n[... ` begins between byte 4090 and byte 4096 and it contains `bytes omitted ...]` (`TestToolsShellRunsInTheRootAndCutsOutput`).
- `tools-invalid-arguments`: `tools.DecodeArguments` of arguments that are not a JSON object returns `map[__invalid__:true]` (`TestDecodeArgumentsOfAnythingButAnObject`).
- `tools-output-item`: `tools.OutputItem(id, text)` is `{"type":"function_call_output","call_id":id,"output":text}` (`TestCallsAndOutputItems`).
- `provider-cache-key`: `Client.Body` of a `chatgpt` request with a `CacheID` of at most 64 characters carries it as `prompt_cache_key` and has no `prompt_cache_options` (`TestProviderCacheKey`).
- `provider-cache-id-format`: `provider.NewCacheID()` matches `^conversation-[0-9a-f]{16}$` and `provider.MaxCacheID` is 64 (`TestProviderCacheIDFormat`).
- `provider-usage-line`: `provider.Usage{Input: 100, Cached: 0, Output: 20, Reasoning: 5}.Line()` is `input=100 cached=0 output=20 reasoning=5` (`TestProviderUsageLine`).
- `provider-input-budget`: `tools.Measure` of a body of 524288 bytes has `InputBudgetBytes` 524288, `OutputReserveTokens` 131072 and `Fits` true; one byte more does not fit (`TestMeasureAgainstTheInputBudget`).
- `provider-response-budget`: `provider.ResponseBudget` is 30 minutes and `provider.NewClient("").ResponseBudget` is 0 (`TestProviderResponseBudget`).
- `provider-url-seam`: with `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` set to a loopback `httptest` server in the session environment, `Client.Respond` for `chatgpt` posts to `<url>/v1/responses`, accepts the SSE frames consumers' fakes write (`response.output_item.done`, then `response.completed` with usage) and returns the items and usage (`TestProviderRespondURLSeam`).
- `provider-credentials`: a ChatGPT login written the way consumers seed it (`$HOME/.kogen/credentials/chatgpt.json`, mode 0600, in a 0700 `.kogen`, with `client_id` `oaiapp_fake`, `access_token`, `refresh_token`, a future `expires_at`, `scope` and `email`) is usable (`TestProviderRespondCredentialsFile`).
- `provider-wait-text`: when the response budget runs out `Respond` fails with a `*sys.Error` of class `provider`, reason `unavailable`, exit 4 and detail `<Label> response wait exceeded <budget>`, with no real time passing (`TestProviderRespondWaitText`).
- `api-protocol`, `api-library`: `api.Protocol` is `kogen-loop/v1` and `api.Library` is `loop/v1` (`TestAPIProtocolAndLibrary`).
- `provider-catalog`: `provider.Catalog()` lists the `Name`s `chatgpt`, `supergrok`, `opencode-go`, `anthropic` and `openai-compatible` in that order; `Models[0]` is `grok-4.7` for supergrok, `kimi-k3` for opencode-go and `claude-opus-5-5` for anthropic, and chatgpt and openai-compatible have no `Models` (`TestProviderCatalog`).
- `sys-run-context`: `(*sys.Session).RunContext` of a command that completes returns its `Status` and `Output` with a nil error as `Run` does and honours `Options.Env` (`printf out; exit 3` is status 3 and output `out`); when the context is cancelled while the command runs it returns the zero `sys.Result{}` and `context.Canceled`, discarding the partial output (`TestSysRunContextCompletes`, `TestSysRunContextCancel`).
- `sys-captured`: `(*sys.Session).StartCaptured` returns a `*sys.CapturedCommand` whose `Snapshot()` while the command runs is `sys.Result{Output: <output so far>}`, `false` and a nil error; `Done()` is closed when the command ends, after which `Snapshot()` is the final result, `true` and the error; `Stop(cancel)` calls `cancel` and joins the command, so `Done()` is closed and `Snapshot()` is `sys.Result{}`, `true` and `context.Canceled` (`TestSysCapturedPartialAndFinished`, `TestSysCapturedStop`).
- `loop-terminal`: `loop.Run` with hooks does not execute a call named in `Round.Terminal` (or `finish` by default), ends the round with `EndTerminal` and `Result.Terminal` set to that call, and runs the other calls of the batch (`TestLoopRunTerminalWithHooks`, `TestLoopRunDefaultTerminalIsFinish`).
- `loop-usage-state`: `loop.UsageOf` of a response with all four counts known has state `complete`, with none known `unknown` and otherwise `partial`; `loop.SumUsage` keeps a category nil when any usage lacks it (`TestLoopUsageState`).

## Differences from consumer expectations

Where an adapted consumer case disagrees with kogen-loop's current behaviour, the case pins the current behaviour:

- Budget expiry text. kogen-executor's `agent/budget_test.go` expects `ChatGPT response wait exceeded 10 minutes` for a ten-minute budget, after its own `NameBudgetExpiry` renames the text. kogen-loop's own detail for a client with `ResponseBudget` of ten minutes is `ChatGPT response wait exceeded 10m0s`, and `ChatGPT response wait exceeded 30 minutes` without a configured budget; `TestProviderRespondWaitText` pins both.
- Size of a raw shell result. kogen's `cli/research_removal_test.go` cuts the output of a command that prints 30000 bytes. `Tools.Run` for `shell` returns `exit status: 0\n` before the command's output, so the raw text is 30015 bytes; the cut is 16384 bytes either way, and `TestToolsShellRunsInTheRootAndCutsOutput` pins both sizes.

## Interface members

One row per member: the consumers that use it, the consumer sources its cases were adapted from (or that use it), and the contract tests that exercise it.

| Interface | Consumers | Derived from | Contract tests |
| --- | --- | --- | --- |
| `api.Library` | kogen, kogen-build | `kogen-build/build/executor_native.go`, `kogen/cli/loop_pin_test.go` | `TestAPIProtocolAndLibrary` |
| `api.Protocol` | kogen | `kogen/cli/loop_pin_test.go` | `TestAPIProtocolAndLibrary` |
| `api.Usage` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `api.Usage.Cached` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `api.Usage.Input` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `api.Usage.Output` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `api.Usage.Reasoning` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `api.Usage.State` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `loop.Handled` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Handled.Handled` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Handled.Output` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Hooks` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Hooks.AfterCall` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Hooks.AfterResponse` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Hooks.BeforeCall` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Hooks.BeforeRequest` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Hooks.HandleCall` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Request` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Request.Input` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Request.Instructions` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Request.Owner` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Request.Tools` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Result.Input` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Result.Response` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Result.Terminal` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Round` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Round.Definitions` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder` |
| `loop.Round.Instructions` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Round.Owner` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Round.Role` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Round.Terminal` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish` |
| `loop.Round.Tools` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.Run` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `loop.SumUsage` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `loop.UsageOf` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopUsageState` |
| `provider.Cache` | kogen-build | `kogen-build/build/build.go` | `TestProviderCacheIdentityPerScope` |
| `provider.Cache.States` | kogen-build | `kogen-build/build/build.go` | `TestProviderCacheIdentityPerScope` |
| `provider.CacheState` | kogen-build | `kogen-build/build/legacy.go`, `kogen-build/build/unit_test.go` | `TestProviderCacheStates` |
| `provider.CacheState.ID` | kogen-build | `kogen-build/build/legacy.go`, `kogen-build/build/legacy_test.go`, `kogen-build/build/unit_test.go` | `TestProviderCacheStates` |
| `provider.CacheState.Response` | kogen-build | `kogen-build/build/legacy.go`, `kogen-build/build/legacy_test.go`, `kogen-build/build/unit_test.go` | `TestProviderCacheStates` |
| `provider.CacheState.Unsupported` | kogen-build | `kogen-build/build/legacy.go`, `kogen-build/build/legacy_test.go`, `kogen-build/build/unit_test.go` | `TestProviderCacheStates` |
| `provider.CacheState.Valid` | kogen-build | `kogen-build/build/legacy.go` | `TestProviderCacheStates` |
| `provider.Catalog` | kogen-setup | `kogen-setup/setup/init_route.go` | `TestProviderCatalog` |
| `provider.CheckSeams` | kogen | `kogen/cli/native.go` | `TestProviderSeamsMustBeLoopback` |
| `provider.ClaudeCodeToken` | kogen, kogen-setup | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens` |
| `provider.Client` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/helper_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/helper_test.go`, `kogen/cli/response_budget_test.go` | `TestProviderRespondCredentialsFile`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondURLSeam`, `TestProviderRespondWaitText`, `TestProviderResponseBudget` |
| `provider.Client.Body` | kogen, kogen-shaping, kogen-build | `kogen/cli/research_removal_test.go`, `kogen-shaping/shape/k18b_test.go`, `kogen-build/build/context.go` | `TestProviderCacheIdentityPerScope`, `TestProviderCacheKey`, `TestProviderToolChoice` |
| `provider.Client.Cache` | kogen-shaping, kogen-build | `kogen-shaping/shape/helper_test.go` | `TestProviderCacheIdentityPerScope` |
| `provider.Client.HTTP` | kogen, kogen-shaping, kogen-setup, kogen-build | `kogen/cli/compatible_login_test.go` | `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.Client.Input` | kogen | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.Client.Login` | kogen | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.Client.LoginWithBaseURL` | kogen | `kogen/cli/native.go` | `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.Client.Now` | kogen-executor, kogen-shaping, kogen-build | `kogen-executor/agent/budget_test.go` | `TestProviderRespondWaitText` |
| `provider.Client.Respond` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/batch.go`, `kogen-shaping/shape/init.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/response_budget_test.go` | `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondCredentialsFile`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondURLSeam`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderToolChoice` |
| `provider.Client.ResponseBudget` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen-executor/agent/budget_test.go`, `kogen/cli/response_budget_test.go` | `TestProviderRespondWaitText`, `TestProviderResponseBudget` |
| `provider.Client.Sleep` | kogen, kogen-executor, kogen-shaping | `kogen/cli/response_budget_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/helper_test.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondWithoutALoginSendsNothing` |
| `provider.Client.Version` | kogen-shaping, kogen-build | `kogen-shaping/shape/shape.go`, `kogen-build/build/executor_native_test.go` | `TestProviderResponseBudget` |
| `provider.ContractBlocks` | kogen-shaping, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/material_test.go`, `kogen-shaping/shape/context.go` | `TestProviderContractBlocksAndFingerprint` |
| `provider.Fingerprint` | kogen-review, kogen-build | `kogen-build/build/builder.go` | `TestProviderContractBlocksAndFingerprint` |
| `provider.Info.Models` | kogen-setup | `kogen-setup/setup/init_route.go` | `TestProviderCatalog` |
| `provider.Info.Name` | kogen, kogen-setup | `kogen/cli/readiness/readiness.go` | `TestProviderCatalog`, `TestProviderRoleSelectsTheProvider` |
| `provider.Input.Reader` | kogen | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.InputBudgetBytes` | kogen-shaping | `kogen-shaping/shape/contract.go` | `TestMeasureAgainstTheInputBudget` |
| `provider.KnownUsage` | kogen-build | `kogen-build/build/records_test.go` | `TestLoopUsageState`, `TestProviderKnownUsage` |
| `provider.KnownUsage.Cached` | kogen-executor, kogen-build | `kogen-build/build/cache_id_test.go` | `TestLoopUsageState`, `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.KnownUsage.Input` | kogen-executor, kogen-build | `kogen-build/build/cache_id_test.go` | `TestLoopUsageState`, `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.KnownUsage.Map` | kogen-shaping | `kogen-shaping/shape/evidence.go` | `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.KnownUsage.Output` | kogen-executor, kogen-build | `kogen-build/build/cache_id_test.go` | `TestLoopUsageState`, `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.KnownUsage.Reasoning` | kogen-executor | `kogen-executor/core/state.go` | `TestLoopUsageState`, `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.KnownUsage.Write` | kogen-build | `kogen-build/build/records_test.go` | `TestProviderKnownUsage`, `TestProviderRespondURLSeam` |
| `provider.Lookup` | kogen | `kogen/cli/readiness/readiness.go` | `TestProviderRoleSelectsTheProvider` |
| `provider.MaxCacheID` | kogen-build | `kogen-build/build/cache_id_test.go` | `TestProviderCacheIDFormat`, `TestProviderCacheKey` |
| `provider.Name` | kogen-executor, kogen-review | `kogen-executor/core/state.go`, `kogen-review/review/independent.go` | `TestProviderRoleSelectsTheProvider` |
| `provider.NewCache` | kogen-shaping, kogen-build | `kogen-build/build/build.go`, `kogen-shaping/shape/helper_test.go` | `TestProviderCacheIdentityPerScope` |
| `provider.NewCacheID` | kogen-shaping, kogen-setup, kogen-build | `kogen-shaping/shape/conversation.go`, `kogen-build/build/context.go` | `TestProviderCacheIDFormat` |
| `provider.NewClient` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-executor/agent/budget_test.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/native.go`, `kogen/cli/response_budget_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderCacheKey`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderToolChoice` |
| `provider.Observer` | kogen-shaping | `kogen-shaping/shape/evidence.go` | `TestProviderRespondURLSeam` |
| `provider.OfficialText` | kogen | `kogen/cli/native.go` | `TestProviderRoleSelectsTheProvider` |
| `provider.Profiles` | kogen | `kogen/cli/native.go` | `TestProviderRoleSelectsTheProvider` |
| `provider.RedirectFunc` | kogen | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens` |
| `provider.Request` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/build.go`, `kogen-shaping/shape/force.go`, `kogen/cli/compatible_login_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderToolChoice` |
| `provider.Request.Cache` | kogen-build | `kogen-build/build/build.go` | `TestProviderCacheIdentityPerScope` |
| `provider.Request.CacheID` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen/cli/research_removal_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/conversation.go` | `TestProviderToolChoice` |
| `provider.Request.Context` | kogen-shaping, kogen-build | `kogen-shaping/shape/audit.go`, `kogen-build/build/build.go` | `TestProviderRespondURLSeam` |
| `provider.Request.Input` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/build.go`, `kogen/cli/compatible_login_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderToolChoice` |
| `provider.Request.Instructions` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/build.go`, `kogen/cli/compatible_login_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderToolChoice` |
| `provider.Request.Role` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/build.go`, `kogen-shaping/shape/force.go`, `kogen/cli/compatible_login_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderToolChoice` |
| `provider.Request.Scope` | kogen, kogen-shaping | `kogen/cli/compatible_login_test.go` | `TestProviderCacheIdentityPerScope`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `provider.Request.ToolChoice` | kogen-shaping, kogen-review, kogen-build | `kogen-shaping/shape/force.go` | `TestProviderToolChoice` |
| `provider.Request.Tools` | kogen, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen/cli/research_removal_test.go`, `kogen-shaping/shape/audit.go`, `kogen-build/build/build.go` | `TestProviderRespondURLSeam`, `TestProviderToolChoice` |
| `provider.RequireLogin` | kogen, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/builder.go`, `kogen-shaping/shape/init.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderRespondCredentialsFile`, `TestProviderRespondWithoutALoginSendsNothing` |
| `provider.Response` | kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/records.go` | `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks`, `TestLoopUsageState` |
| `provider.Response.Items` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-shaping/shape/batch.go` | `TestLoopRunHooksSeeTheRoundInOrder`, `TestProviderRespondSingle`, `TestProviderRespondURLSeam` |
| `provider.Response.Known` | kogen-executor, kogen-shaping, kogen-build | `kogen-build/build/records.go` | `TestLoopUsageState`, `TestProviderRespondURLSeam` |
| `provider.Response.Model` | kogen-build | `kogen-build/build/executor_native.go` | `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks`, `TestProviderRespondURLSeam` |
| `provider.Response.OperationID` | kogen-build | `kogen-build/build/build.go` | `TestProviderRespondURLSeam` |
| `provider.Response.Usage` | kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-shaping/shape/audit.go`, `kogen-build/build/cache_id_test.go` | `TestProviderRespondURLSeam` |
| `provider.ResponseBudget` | kogen, kogen-executor, kogen-build | `kogen/cli/response_budget_test.go` | `TestProviderResponseBudget` |
| `provider.Role` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/k_reviewretry_safety_test.go`, `kogen-shaping/shape/init.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/readiness/readiness.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondCredentialsFile`, `TestProviderRespondFailures`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderRoleSelectsTheProvider`, `TestProviderToolChoice` |
| `provider.Role.BaseURL` | kogen, kogen-executor, kogen-shaping, kogen-setup | `kogen/cli/compatible_login_test.go` | `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRoleSelectsTheProvider` |
| `provider.Role.Effort` | kogen, kogen-executor, kogen-shaping, kogen-setup | `kogen/cli/compatible_login_test.go` | `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRoleSelectsTheProvider`, `TestProviderToolChoice` |
| `provider.Role.Model` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/k_reviewretry_safety_test.go`, `kogen-shaping/shape/init.go`, `kogen/cli/compatible_login_test.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderRoleSelectsTheProvider`, `TestProviderToolChoice` |
| `provider.Role.Provider` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/k_reviewretry_safety_test.go`, `kogen-shaping/shape/init.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/readiness/readiness.go` | `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderRoleSelectsTheProvider`, `TestProviderToolChoice` |
| `provider.Status` | kogen, kogen-setup | `kogen/cli/native.go` | `TestProviderRespondCredentialsFile`, `TestProviderRespondWithoutALoginSendsNothing` |
| `provider.StdinInput` | kogen | `kogen/cli/native.go` | `TestProviderLoginSavesKeysAndTokens` |
| `provider.SupportsToolChoice` | kogen-shaping, kogen-review, kogen-build | `kogen-build/build/k_reviewretry_safety_test.go`, `kogen-shaping/shape/force.go` | `TestProviderToolChoice` |
| `provider.Usage` | kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-shaping/shape/init.go`, `kogen-build/build/cache_id_test.go` | `TestProviderRespondURLSeam`, `TestProviderUsageLine` |
| `provider.Usage.Add` | kogen-shaping, kogen-setup | `kogen-shaping/shape/contract.go`, `kogen-shaping/shape/decision.go` | `TestProviderUsageLine` |
| `provider.Usage.Cached` | kogen-executor, kogen-shaping | `kogen-shaping/shape/refine.go`, `kogen-executor/core/state.go` | `TestProviderRespondURLSeam`, `TestProviderUsageLine` |
| `provider.Usage.Input` | kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-shaping/shape/refine.go`, `kogen-build/build/cache_id_test.go` | `TestProviderRespondURLSeam`, `TestProviderUsageLine` |
| `provider.Usage.Line` | kogen-shaping, kogen-setup | `kogen-shaping/shape/contract.go`, `kogen-shaping/shape/decision.go` | `TestProviderUsageLine` |
| `provider.Usage.Output` | kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-shaping/shape/refine.go`, `kogen-build/build/cache_id_test.go` | `TestProviderRespondURLSeam`, `TestProviderUsageLine` |
| `provider.Usage.Reasoning` | kogen-executor, kogen-shaping | `kogen-shaping/shape/refine.go`, `kogen-executor/core/state.go` | `TestProviderRespondURLSeam`, `TestProviderUsageLine` |
| `provider.ValidCacheStates` | kogen-build | `kogen-build/build/state.go` | `TestProviderCacheStates` |
| `sys.AsError` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/helper_test.go`, `kogen-coordinator/git/lock_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/batch.go`, `kogen-shaping/shape/init.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/native.go` | `TestAsErrorFindsTheErrorInAChain`, `TestErrTimeoutObservationIsAStoppingError`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderSeamsMustBeLoopback`, `TestProviderToolChoice` |
| `sys.CapturedCommand.Done` | kogen-verification | `kogen-verification/verify/concurrent.go` | `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop` |
| `sys.CapturedCommand.Snapshot` | kogen-verification | `kogen-verification/verify/concurrent.go` | `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop` |
| `sys.CapturedCommand.Stop` | kogen-verification | `kogen-verification/verify/concurrent.go` | `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop` |
| `sys.EnableSupervisor` | kogen, kogen-review, kogen-build | `kogen/cli/main.go` | `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor` |
| `sys.ErrTimeoutObservation` | kogen-verification, kogen-shaping | `kogen-shaping/shape/refine_test.go`, `kogen-verification/verify/probe_deadline_test.go` | `TestErrTimeoutObservationIsAStoppingError` |
| `sys.Error` | kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/stop.go`, `kogen-coordinator/project/config_test.go`, `kogen-shaping/shape/approve_test.go` | `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestImageToolDeliversPixelsAndEvents` |
| `sys.Error.Class` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/executor_native.go`, `kogen-build/build/stop.go`, `kogen-coordinator/git/helper_test.go`, `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/batch.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/compatible_login_test.go` | `TestErrorLine`, `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestImageToolDeliversPixelsAndEvents`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderSeamsMustBeLoopback`, `TestProviderToolChoice` |
| `sys.Error.Detail` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/stop.go`, `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/compatible_login_test.go` | `TestErrorLine`, `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestImageToolDeliversPixelsAndEvents`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondWaitText`, `TestProviderResponseBudget` |
| `sys.Error.Error` | kogen-coordinator, kogen-shaping, kogen-setup | `kogen-coordinator/git/helper_test.go`, `kogen-shaping/shape/approve_test.go` | `TestErrorLine`, `TestErrorRenderLines` |
| `sys.Error.Exit` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/stop.go`, `kogen-coordinator/git/helper_test.go`, `kogen-coordinator/git/lock_test.go`, `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/init.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/native.go` | `TestAsErrorFindsTheErrorInAChain`, `TestErrorLine`, `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestImageToolDeliversPixelsAndEvents`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderSeamsMustBeLoopback` |
| `sys.Error.Lines` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-shaping/shape/approve_test.go` | `TestErrorLine`, `TestErrorRenderLines` |
| `sys.Error.ProviderFailure` | kogen-shaping, kogen-build | `kogen-build/build/stop.go`, `kogen-shaping/shape/refine_test.go` | `TestErrorProviderFailure`, `TestImageToolDeliversPixelsAndEvents` |
| `sys.Error.Reason` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/stop.go`, `kogen-coordinator/git/helper_test.go`, `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-executor/agent/budget_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/batch.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/compatible_login_test.go` | `TestErrorLine`, `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestImageToolDeliversPixelsAndEvents`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondSingle`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderSeamsMustBeLoopback`, `TestProviderToolChoice` |
| `sys.Error.Render` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-build | `kogen-build/build/stop.go`, `kogen-coordinator/project/config_test.go`, `kogen-coordinator/project/intent_test.go`, `kogen-shaping/shape/refine_test.go`, `kogen/cli/compatible_login_test.go`, `kogen/cli/native.go` | `TestErrorLine`, `TestErrorProviderFailure`, `TestErrorRenderLines`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin` |
| `sys.Fail` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-executor/agent/budget_test.go` | `TestAsErrorFindsTheErrorInAChain`, `TestErrorLine` |
| `sys.Interrupted` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/executor_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/batch_test.go`, `kogen-shaping/shape/shape_test.go`, `kogen-verification/verify/interrupt_test.go` | `TestInterruptedExitCodes`, `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.Interrupted.ExitCode` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-build | `kogen/cli/native.go`, `kogen-shaping/shape/approve.go`, `kogen-build/build/build.go` | `TestInterruptedExitCodes`, `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.Interrupted.Signal` | kogen-executor, kogen-verification, kogen-shaping, kogen-build | `kogen-build/build/executor_test.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/batch_test.go`, `kogen-shaping/shape/shape_test.go`, `kogen-verification/verify/interrupt_test.go` | `TestInterruptedExitCodes`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.MaybeSupervise` | kogen, kogen-review, kogen-build | `kogen/cli/main.go` | `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor` |
| `sys.New` | kogen, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-verification/features/steps/probetrust.go`, `kogen/cli/engine.go` | `TestNewTakesTheProcessEnvironment` |
| `sys.NewWith` | kogen, kogen-coordinator, kogen-executor, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/helper_test.go`, `kogen-shaping/shape/helper_test.go` | `TestProviderSeamsMustBeLoopback`, `TestRunStatusOutputEnv`, `TestSessionOutputAndEnvironment`, `TestToolsListAndSearchThroughGit`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `sys.Options` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/baseline.go`, `kogen-coordinator/git/commit.go`, `kogen-shaping/shape/init.go`, `kogen-verification/verify/attempt.go`, `kogen-verification/verify/probe.go`, `kogen-verification/verify/probe_deadline_test.go` | `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunStatusOutputEnv`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait`, `TestSysRunContextCancel`, `TestSysRunContextCompletes` |
| `sys.Options.Context` | kogen-verification, kogen-shaping | `kogen-verification/verify/probe_deadline_test.go` | `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.Options.Env` | kogen, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-shaping/shape/init.go` | `TestRunStatusOutputEnv`, `TestSysRunContextCompletes` |
| `sys.Options.FinishOnInterrupt` | kogen-coordinator | `kogen-coordinator/git/commit.go` | `TestRunFinishOnInterruptWaitsForTheCommand` |
| `sys.Options.KillGroupOnExit` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-coordinator/git/commit.go`, `kogen-verification/verify/attempt.go` | `TestRunKillGroupOnExit` |
| `sys.Options.RefuseForeignKill` | kogen-verification | `kogen-verification/verify/probe.go` | `TestRunRefusesAForeignKill` |
| `sys.Options.Timeout` | kogen-verification, kogen-shaping, kogen-setup | `kogen-verification/verify/probe_deadline_test.go` | `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.Result` | kogen, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-verification/verify/probe.go` | `TestRunRefusesAForeignKill`, `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop`, `TestSysRunContextCancel`, `TestSysRunContextCompletes` |
| `sys.Result.Output` | kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/baseline.go`, `kogen-coordinator/git/commit.go`, `kogen-shaping/shape/init.go`, `kogen-verification/verify/attempt.go`, `kogen-verification/verify/probe.go` | `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunStatusOutputEnv`, `TestSysCapturedPartialAndFinished`, `TestSysRunContextCompletes` |
| `sys.Result.Status` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/baseline.go`, `kogen-coordinator/git/commit.go`, `kogen-shaping/shape/init.go`, `kogen-verification/verify/attempt.go`, `kogen-verification/verify/probe.go` | `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunStatusOutputEnv`, `TestRunTimeout`, `TestSysCapturedPartialAndFinished`, `TestSysRunContextCompletes` |
| `sys.Result.TimedOut` | kogen-verification, kogen-shaping, kogen-setup | `kogen-verification/verify/attempt.go` | `TestRunStatusOutputEnv`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.Session` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/helper_test.go`, `kogen-coordinator/git/commit.go`, `kogen-shaping/shape/approve_test.go`, `kogen-shaping/shape/helper_test.go`, `kogen-shaping/shape/init.go`, `kogen-shaping/shape/refine.go`, `kogen-verification/verify/attempt.go`, `kogen-verification/verify/probe.go`, `kogen-verification/verify/probe_deadline_test.go`, `kogen/cli/native.go`, `kogen/cli/research_removal_test.go` | `TestDecodeArgumentsOfAnythingButAnObject`, `TestDefinitionsOfTheGenericTools`, `TestDocumentationFetchesWithTheUserAgent`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestProviderRespondCredentialsFile`, `TestProviderRespondFailures`, `TestProviderRespondSingle`, `TestProviderRespondURLSeam`, `TestProviderRespondWaitText`, `TestProviderRespondWithoutALoginSendsNothing`, `TestProviderResponseBudget`, `TestProviderToolChoice`, `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait`, `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt`, `TestToolsListAndSearchThroughGit`, `TestToolsProbeBelongsToTheCaller`, `TestToolsReadFileNumbersLines`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsShellRunsInTheRootAndCutsOutput`, `TestToolsWriteFileRefusesProtectedPaths` |
| `sys.Session.Context` | kogen, kogen-verification, kogen-setup, kogen-review, kogen-build | `kogen-verification/verify/interrupt_test.go`, `kogen/cli/engine.go` | `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.Session.Cwd` | kogen, kogen-verification, kogen-shaping, kogen-setup | `kogen-shaping/shape/init.go`, `kogen-verification/verify/interrupt_test.go`, `kogen/cli/engine.go` | `TestNewTakesTheProcessEnvironment`, `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunStatusOutputEnv`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait`, `TestSessionOutputAndEnvironment`, `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop`, `TestSysRunContextCancel`, `TestSysRunContextCompletes` |
| `sys.Session.Debug` | kogen | `kogen/cli/engine.go` | `TestSessionOutputAndEnvironment` |
| `sys.Session.Env` | kogen, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen/cli/readiness/readiness_test.go`, `kogen-verification/verify/evidence_test.go`, `kogen-shaping/shape/approve.go` | `TestNewTakesTheProcessEnvironment`, `TestSessionOutputAndEnvironment` |
| `sys.Session.Err` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen/cli/engine.go` | `TestSessionInterruptRecordsTheFirstSignal`, `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.Session.Getenv` | kogen, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen/cli/native.go`, `kogen-verification/verify/probe.go`, `kogen-shaping/shape/approve.go` | `TestNewTakesTheProcessEnvironment`, `TestSessionOutputAndEnvironment` |
| `sys.Session.Groups` | kogen, kogen-verification, kogen-build | `kogen-verification/verify/probe.go` | `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.Session.Interrupt` | kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-shaping/shape/batch_test.go`, `kogen-verification/verify/interrupt_test.go` | `TestSessionInterruptRecordsTheFirstSignal` |
| `sys.Session.LookupEnv` | kogen-verification | `kogen-verification/verify/sweep_test.go` | `TestSessionOutputAndEnvironment` |
| `sys.Session.Out` | kogen, kogen-shaping, kogen-build | `kogen/cli/readiness.go`, `kogen-shaping/shape/shape.go`, `kogen-build/build/stop.go` | `TestSessionOutputAndEnvironment` |
| `sys.Session.Progress` | kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-coordinator/git/lock.go`, `kogen-verification/verify/readiness.go`, `kogen-shaping/shape/audit.go` | `TestSessionOutputAndEnvironment` |
| `sys.Session.Puts` | kogen, kogen-shaping, kogen-setup, kogen-build | `kogen/cli/native.go`, `kogen-shaping/shape/approve.go`, `kogen-build/build/baseline.go` | `TestSessionOutputAndEnvironment` |
| `sys.Session.Run` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/baseline.go`, `kogen-coordinator/git/commit.go`, `kogen-shaping/shape/init.go`, `kogen-verification/verify/attempt.go`, `kogen-verification/verify/probe.go` | `TestRunInterruptStopsTheCommandAndRefusesLaterOnes`, `TestRunKillGroupOnExit`, `TestRunRefusesAForeignKill`, `TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor`, `TestRunStatusOutputEnv`, `TestRunTimeout`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.Session.RunContext` | kogen-verification, kogen-shaping | `kogen-verification/verify/probe.go`, `kogen-verification/verify/attempt.go`, `kogen-shaping/shape/unpassable.go` | `TestSysRunContextCancel`, `TestSysRunContextCompletes` |
| `sys.Session.StartCaptured` | kogen-verification | `kogen-verification/verify/concurrent.go` | `TestSysCapturedPartialAndFinished`, `TestSysCapturedStop` |
| `sys.Session.Stderr` | kogen, kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup, kogen-build | `kogen-build/build/helper_test.go`, `kogen-shaping/shape/helper_test.go` | `TestNewTakesTheProcessEnvironment`, `TestSessionOutputAndEnvironment` |
| `sys.Session.Stdout` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/helper_test.go`, `kogen-shaping/shape/helper_test.go` | `TestNewTakesTheProcessEnvironment`, `TestProviderLoginSavesKeysAndTokens`, `TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin`, `TestSessionOutputAndEnvironment` |
| `sys.Session.WatchSignals` | kogen, kogen-shaping, kogen-review, kogen-build | `kogen/cli/engine.go` | `TestSessionWatchSignalsTurnsASignalIntoAnInterrupt` |
| `sys.Terminate` | kogen, kogen-build | `kogen/cli/engine.go`, `kogen-build/build/executor_native_test.go` | `TestRunFinishOnInterruptWaitsForTheCommand`, `TestRunKillGroupOnExit`, `TestRunTimeoutOptionsContextEndsTheCustodyWait` |
| `sys.TmpPath` | kogen-coordinator, kogen-verification, kogen-shaping, kogen-setup | `kogen-coordinator/git/snapshot.go`, `kogen-shaping/shape/common.go` | `TestTmpPathIsUnique` |
| `tools.AsAny` | kogen-executor | `kogen-executor/agent/defs.go` | `TestDefinitionsOfTheGenericTools` |
| `tools.Call` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/executor_native.go`, `kogen-build/build/review_delivery_test.go`, `kogen-shaping/shape/conversation.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `tools.Call.Args` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestLoopRunHooksSeeTheRoundInOrder` |
| `tools.Call.Arguments` | kogen-review, kogen-build | `kogen-build/build/builder.go`, `kogen-build/build/executor_native.go`, `kogen-build/build/review_delivery_test.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunTerminalWithHooks` |
| `tools.Call.CallID` | kogen-build | `kogen-build/build/builder.go` | `TestCallsAndOutputItems` |
| `tools.Call.Item` | kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/review_delivery_test.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunTerminalWithHooks` |
| `tools.Call.Name` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/review_delivery_test.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunDefaultTerminalIsFinish`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks` |
| `tools.Call.Output` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go`, `kogen-shaping/shape/conversation.go` | `TestCallsAndOutputItems`, `TestImageToolDeliversPixelsAndEvents` |
| `tools.Calls` | kogen-shaping, kogen-setup, kogen-review | `kogen-shaping/shape/audit.go`, `kogen-shaping/shape/contract.go`, `kogen-review/review/independent.go` | `TestCallsAndOutputItems` |
| `tools.Cut` | kogen, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen/cli/research_removal_test.go` | `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.DecodeArguments` | kogen, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go` | `TestDecodeArgumentsOfAnythingButAnObject` |
| `tools.Definition` | kogen, kogen-executor, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-executor/agent/defs_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools` |
| `tools.Deliver` | kogen-shaping, kogen-build | `kogen-shaping/shape/shape.go`, `kogen-build/build/build.go` | `TestImageToolDeliversPixelsAndEvents` |
| `tools.Documentation` | kogen, kogen-shaping | `kogen-shaping/shape/refine.go`, `kogen/cli/research_removal_test.go` | `TestDocumentationFetchesWithTheUserAgent`, `TestDocumentationOutputIsBounded` |
| `tools.Documentation.Lookup` | kogen | `kogen/cli/research_removal_test.go` | `TestDocumentationFetchesWithTheUserAgent`, `TestDocumentationOutputIsBounded` |
| `tools.Documentation.UserAgent` | kogen-shaping | `kogen-shaping/shape/refine.go` | `TestDocumentationFetchesWithTheUserAgent` |
| `tools.DocumentationTool` | kogen, kogen-executor, kogen-shaping | `kogen-executor/agent/defs_test.go`, `kogen-shaping/shape/refine.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestDocumentationFetchesWithTheUserAgent`, `TestToolsRefuseNamesThatAreNotEnabled` |
| `tools.Git` | kogen-executor | `kogen-executor/agent/git.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Git.Head` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Git.Run` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Git.Tree` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.GitResult` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.GitResult.Status` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.GitResult.Stderr` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.GitResult.Stdout` | kogen-executor | `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.ImageEntries` | kogen-build | `kogen-build/build/material.go` | `TestImageToolDeliversPixelsAndEvents`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.ImageEntry` | kogen-build | `kogen-build/build/material.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.ImageEntry.Meta` | kogen-build | `kogen-build/build/material.go` | `TestImageToolDeliversPixelsAndEvents`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.InputBudgetBytes` | kogen, kogen-shaping, kogen-review, kogen-build | `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.ListFilesTool` | kogen, kogen-executor, kogen-shaping | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/git_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestToolsListAndSearchThroughGit`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Measure` | kogen, kogen-shaping, kogen-build | `kogen-shaping/shape/window_test.go`, `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Measurement` | kogen-build | `kogen-build/build/review_budget_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Measurement.Fits` | kogen, kogen-shaping, kogen-build | `kogen-shaping/shape/window_test.go`, `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Measurement.InputBudgetBytes` | kogen, kogen-build | `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Measurement.OutputReserveTokens` | kogen, kogen-build | `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Measurement.RenderedBytes` | kogen, kogen-shaping, kogen-build | `kogen-shaping/shape/window_test.go`, `kogen/cli/research_removal_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.Output` | kogen, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/records.go`, `kogen-shaping/shape/conversation.go`, `kogen/cli/research_removal_test.go` | `TestCallsAndOutputItems`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunHookErrorStopsTheRound`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks`, `TestOutputValueIsTheTextOrTheParts`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Output.Cut` | kogen, kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen/cli/research_removal_test.go` | `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Output.Parts` | kogen | `kogen/cli/research_removal_test.go` | `TestImageToolDeliversPixelsAndEvents`, `TestOutputValueIsTheTextOrTheParts`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Output.Text` | kogen, kogen-executor, kogen-shaping, kogen-build | `kogen-build/build/executor_native.go`, `kogen-build/build/records.go`, `kogen/cli/research_removal_test.go` | `TestCallsAndOutputItems`, `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents`, `TestLoopRunHooksSeeTheRoundInOrder`, `TestLoopRunTerminalWithHooks`, `TestOutputValueIsTheTextOrTheParts`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Output.Typed` | kogen-executor, kogen-build | `kogen-build/build/records.go` | `TestImageToolDeliversPixelsAndEvents`, `TestOutputValueIsTheTextOrTheParts`, `TestToolsRepoRunsTheGitOfTheCaller`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Output.Value` | kogen-review, kogen-build | `kogen-build/build/executor_native.go` | `TestOutputValueIsTheTextOrTheParts` |
| `tools.OutputItem` | kogen, kogen-build | `kogen-build/build/builder.go` | `TestCallsAndOutputItems`, `TestImageToolDeliversPixelsAndEvents`, `TestOutputValueIsTheTextOrTheParts`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.OutputReserveTokens` | kogen-shaping, kogen-build | `kogen-shaping/shape/window.go`, `kogen-build/build/k_reviewretry_safety_test.go` | `TestMeasureAgainstTheInputBudget` |
| `tools.ReadEvent` | kogen-shaping, kogen-review, kogen-build | `kogen-build/build/executor_native.go` | `TestImageToolDeliversPixelsAndEvents` |
| `tools.ReadFileTool` | kogen, kogen-executor, kogen-shaping, kogen-build | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDecodeArgumentsOfAnythingButAnObject`, `TestDefinitionsOfTheGenericTools`, `TestToolsReadFileNumbersLines`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsWriteFileRefusesProtectedPaths` |
| `tools.Replay` | kogen-shaping, kogen-setup, kogen-review, kogen-build | `kogen-build/build/executor_native.go`, `kogen-shaping/shape/batch.go` | `TestReplayKeepsWhatTheProviderAcceptsBack` |
| `tools.ReplayItem` | kogen | `kogen/test/migration/drivers/review_refine_working_room/main.go` | `TestReplayKeepsWhatTheProviderAcceptsBack` |
| `tools.SearchTextTool` | kogen, kogen-executor, kogen-shaping | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/git_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestToolsListAndSearchThroughGit`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.ShellTool` | kogen, kogen-executor | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Tools` | kogen, kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Tools.Call` | kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go` | `TestDecodeArgumentsOfAnythingButAnObject`, `TestImageToolDeliversPixelsAndEvents` |
| `tools.Tools.Definition` | kogen-executor | `kogen-executor/core/util.go` | `TestDefinitionsOfTheGenericTools` |
| `tools.Tools.Documentation` | kogen-shaping | `kogen-shaping/shape/refine.go` | `TestDocumentationFetchesWithTheUserAgent` |
| `tools.Tools.Enabled` | kogen, kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go`, `kogen-executor/agent/tools_test.go` | `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Tools.Excluded` | kogen-build | `kogen-build/build/executor_native.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Tools.Probe` | kogen-executor, kogen-shaping | `kogen-executor/agent/tools_test.go` | `TestToolsProbeBelongsToTheCaller` |
| `tools.Tools.Protected` | kogen-build | `kogen-build/build/executor_native.go` | `TestToolsWriteFileRefusesProtectedPaths` |
| `tools.Tools.Repo` | kogen-executor, kogen-shaping, kogen-build | `kogen-build/build/review_delivery_test.go`, `kogen-executor/agent/git_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Tools.Root` | kogen, kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.Tools.Run` | kogen, kogen-executor, kogen-shaping, kogen-build | `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestToolsProbeBelongsToTheCaller`, `TestToolsRepoRunsTheGitOfTheCaller`, `TestToolsShellRunsInTheRootAndCutsOutput` |
| `tools.Tools.Session` | kogen, kogen-executor, kogen-shaping, kogen-review, kogen-build | `kogen-build/build/review_delivery_test.go` | `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.ViewImageTool` | kogen, kogen-executor, kogen-shaping | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestImageToolDeliversPixelsAndEvents`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsRepoRunsTheGitOfTheCaller` |
| `tools.WriteFileTool` | kogen, kogen-executor | `kogen-executor/agent/defs_test.go`, `kogen-executor/agent/tools_test.go`, `kogen/cli/research_removal_test.go` | `TestDefinitionsOfTheGenericTools`, `TestToolsRefuseNamesThatAreNotEnabled`, `TestToolsWriteFileRefusesProtectedPaths` |
