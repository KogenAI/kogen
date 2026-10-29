# kogen-loop caller contract v1

Status: maintained local caller contract, adopted 26 October 2026 from external reference revision 2. The reference's orchestrator-owned frozen status is historical, not authority for this tree. Changes go through this file and `api/` together, with the version rule below. Protocol id: `kogen-loop/v1`. Library API id: `loop/v1`.

kogen-loop has two caller surfaces with the same semantics:

1. **Go library** (`kogen-loop/loop`, `kogen-loop/provider`, `kogen-loop/tools`, `kogen-loop/sys`). Hosts can call it in process; this tree makes no current Kogen consumer claim.
2. **Process protocol** (`kogen-loop run`, `kogen-loop capabilities`). Independent callers use it: one task in, JSON Lines events out, exit code.

Neither surface knows Kogen's approval, Intent, baseline, verification, review, commit or checkpoint semantics.

## 1. Invariants

- **L1 Claims, not completion.** A round ends when the model calls a terminal tool (default `finish`) or answers without a tool call. The ending and any summary are model claims. kogen-loop never reports work as verified, approved or complete. No task field, flag or tool lets a model or caller mark a task successful.
- **L2 Byte fidelity.** Moving code into kogen-loop doesn't change model-facing bytes or wire bodies:
  - tool definitions given the same template variables;
  - tool result texts and the 16384-byte cut;
  - replay items;
  - request bodies, cache identity placement, retry and stream accumulation.
  The adopted golden tests guard these compatibility bytes.
- **L3 No hidden fallback.** No provider, route, key or model substitution and no extra retries beyond the provider policy moved from Kogen (3 transport attempts, one unreadable-answer retry, one refresh after a 401 for sign-in routes). Refusals are reported honestly.
- **L4 Unknown stays unknown.** Usage comes from provider-reported fields only. Missing values are `null` and the usage `state` is `partial` or `unknown`. Nothing is estimated.
- **L5 Credentials.** The loop reads the existing store at `$HOME/.kogen/credentials/<provider>.json` (same format, 0600) with the same login/refresh behavior. It never prints, copies, proxies or exports tokens. Signing in remains the caller's job (`kogen provider login …`, or `provider.Login` for library callers).

  **openai-compatible keys are origin-bound.** The saved key (`~/.kogen/credentials/openai-compatible.json`, now `provider`, `api_key` and `origin`) is sent only to the origin it was saved for: scheme, lower-case hostname and effective port, without path, query or fragment. Library callers save it with `Client.LoginWithBaseURL(ctx, session, name, baseURL, redirect)`, passing the base URL the user supplied (never one taken from a repository's inference roles); `Client.Login` stays for every other provider and refuses openai-compatible rather than save an unbound key, and `baseURL` is ignored for other providers. A key login needs an HTTPS URL; an HTTP one is refused with the saved credential untouched. Before any request, a different destination origin (other scheme, host, subdomain or port) fails with a provider error naming both origins and sends nothing; a saved key whose origin is missing (written before this change) fails with a message to log in again, even on loopback. Matching HTTPS origins work with any URL path. Plain HTTP is allowed only keyless, to `localhost` or a literal loopback IP (names are never resolved); HTTPS keyless use is unchanged. Diagnostics never carry the key. There is no new CLI command or option.
- **L6 Process custody.** Shell tools run in their own process groups. Cancellation, deadline or interruption terminates every group the loop started (SIGTERM, then SIGKILL after a bounded wait) before the call returns, including a shell that is still starting or is registered late. Every round also ends its own groups when it ends in any way (a terminal call, a no-call answer, a hook or requester error as well as cancellation, deadline or interruption), background processes included; they stay alive between the round's calls. Groups started before the round and processes that left their group (`setsid`, daemons) are not touched. A host binary calls `sys.MaybeSupervise(os.Args[1:])` and `sys.EnableSupervisor()` first in `main`, as Kogen does. `cmd/kogen-loop` does so too, so a killed host still takes its command groups down: the supervisor finishes the whole-group SIGTERM-then-SIGKILL escalation even when the direct shell exits on SIGTERM and a descendant ignores it, and a shell that already ended leaves a small keeper in its group while members remain, so a killed host still stops them. A library caller that skips this keeps only the in-process termination.  Shell calls have no per-call time limit.

## 2. Go library API (`loop/v1`)

```go
package loop

// Request is one model request of a round.
type Request struct {
    Owner        string        // conversation owner label (e.g. "build"); used for cache identity and events
    Role         provider.Role // provider, model, effort, base URL
    Instructions string
    Input        []any         // Responses-style input items
    Tools        []any         // model-facing tool definitions, sent verbatim
}

// Requester sends one request. It returns the response and the input actually sent.
type Requester interface {
    Request(ctx context.Context, r Request) (*provider.Response, []any, error)
}

// Direct is the provider-backed Requester (provider.Client.Respond). It always refuses an
// over-budget request (typed error loop/context_budget_exceeded) before sending it, never
// clipping, and takes an optional provider.Observer for attempt records.
type Direct struct {
    Client   *provider.Client
    Session  *sys.Session
    Observer provider.Observer  // nil: none
    CacheID  string             // one cache identity per conversation (kept across rounds)
    Cache    *provider.Cache
}

// Handled is a caller's answer to a tool call it intercepts.
type Handled struct {
    Handled  bool         // false: the engine runs the call with Round.Tools
    Output   tools.Output // the call's output when Handled and not Terminal
    Terminal bool         // the call ends the round after this batch (no output is appended)
}

// Hooks let a caller attach custody, checkpoints, events and policy without forking the engine.
// Every hook is optional. A hook error stops the round and is returned unchanged.
type Hooks struct {
    BeforeRequest func(ctx context.Context, input []any) error
    AfterResponse func(ctx context.Context, resp *provider.Response, sent []any) error
    BeforeCall    func(ctx context.Context, call tools.Call, input []any) error
    HandleCall    func(ctx context.Context, call tools.Call) (Handled, error)
    AfterCall     func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error
}

// Round describes one round.
type Round struct {
    Owner        string
    Role         provider.Role
    Instructions string
    Definitions  []any        // tool definitions sent to the model
    Tools        *tools.Tools // executes non-handled calls (enabled set, protected/excluded paths)
    Terminal     []string     // names that end the round without execution; default ["finish"]
}

type Ending string

const (
    EndTerminal Ending = "terminal" // a terminal tool was called
    EndNoCall   Ending = "no_call"  // the model answered without any tool call
)

type Result struct {
    Ending   Ending
    Terminal *tools.Call        // last terminal call of the final batch (EndTerminal only)
    Input    []any              // conversation after the round: sent input + replayed response items + outputs of non-terminal calls
    Response *provider.Response // last response
    Requests int                // requests sent in this round
}

func Run(ctx context.Context, rd Round, input []any, rq Requester, h Hooks) (Result, error)
```

**Engine order (normative).** This is exactly the order Kogen's builder round used at `56eecd57`:

1. `BeforeRequest(input)`.
2. `resp, sent := rq.Request(...)`.
3. `AfterResponse(resp, sent)`.
4. `input = sent ++ tools.Replay(resp.Items)` and `calls = tools.Calls(resp.Items)`.
5. For each call, in order:
   1. Return `ctx.Err()` if it's set.
   2. `BeforeCall(call, input ++ outs)`.
   3. If the name is in `Terminal`, mark it terminal and don't execute it. When a batch has several terminal calls, the **last** one is `Result.Terminal`, as Kogen's builder keeps it; earlier ones stay unanswered. Every call in a batch runs, including calls after a terminal call.
   4. Otherwise take `HandleCall` if it's set and handled; if not, `out, err := Tools.CallContext(ctx, call)` and use `out.Cut()`. Intercepted `HandleCall` output stays host-owned and is not cut. `err` is returned unchanged as a stop for shell interruption.
   5. `AfterCall(call, out, terminal, input ++ outs)`.
   6. Append `call.Output(out)` to `outs` unless the call is terminal.
6. If no call is terminal and `len(calls) > 0`, set `input = input ++ outs` and go to step 1.
7. Otherwise return `Result{Ending, Terminal, Input: input ++ outs, …}`. The ending is `EndNoCall` when `len(calls) == 0`.

Cancellation observed after a response/call hook returns nil stops the round
before executing a tool, starting another request or returning an ending. A hook error still
takes precedence and is returned unchanged.

### Input window budget (fixed)

The complete rendered request (instructions, tools, cache placement) is measured inclusively against a fixed 524288-byte ceiling (`provider.InputBudgetBytes`), or a smaller documented bound of the role's model family. There is no option to lower it: `loop.FailOverBudget` and `loop.Direct` have no budget field. `loop.Direct` always applies `FailOverBudget`; a request over the ceiling is refused with `loop/context_budget_exceeded` (message `<owner>: complete next request N bytes exceeds LIMIT; reserve R tokens. Nothing was sent and nothing was clipped.`) before anything is sent, and the input is never clipped. `tools.Measure` reports the rendered size, the ceiling and the output reserve.

### Client response budget (Go library)

`provider.Client.ResponseBudget time.Duration` is a library-only lower-only option: no CLI flag, task field or provider protocol change exists. The unit is a Go `time.Duration`. Zero keeps the package constant `provider.ResponseBudget` (30 minutes), with unchanged wire bytes, diagnostics and retry behavior. A nonzero value must be in the inclusive range 1 second through 30 minutes; `Respond` refuses anything else before credentials, network traffic or backoff with `*sys.Error` (class `provider`, reason `refused`, exit 4, detail `response budget must be zero or between 1s and 30m0s`).

- The effective logical-call budget is the client value, or 30 minutes for zero; nothing else selects it.
- The budget stays absolute: it covers credential waits, refresh, transport, stream reads, retry backoff and retries; bytes and heartbeats never renew it. No retry is added.
- Every transport attempt also has default silence timeouts, for everyone and without a caller-facing option; they end only that attempt and never renew or extend the absolute budget. The first byte must arrive within 90 s for ChatGPT and 45 s for Anthropic Messages and every other provider; after that no more than 180 s may pass between bytes. For streams (Responses, Messages) the first-byte clock starts at request dispatch, response headers are not a stream byte, and any actual body byte, a heartbeat or a partial frame included, renews the idle clock (a read of zero bytes does not). For non-streaming Chat Completions the headers are the first byte, idle starts at the headers and body bytes renew it. Elapsed time is read from `Client.Now`; a blocked header wait or body read is cancelled when its limit passes rather than waiting for another byte. A byte arriving strictly before the limit is valid; at the limit the attempt has expired.
- An expired attempt is a transient failure (outcome `failed`, `end_reason` `idle`, also on Chat Completions) whose detail is `no first byte within 90 s`, `no first byte within 45 s` or `stream idle for 180 s`. It is retried by the existing attempt policy with unchanged count and 2 s/8 s backoff, and is single-shot with `Request.Single` on ChatGPT. The absolute budget and caller cancellation take precedence over an overlapping timeout. Request bytes are unchanged.
- Expiry uses the existing path: `provider/unavailable`, exit 4, provider-labelled. With `ResponseBudget` zero the detail is exactly `response wait exceeded 30 minutes`. With a nonzero value the detail is `response wait exceeded ` plus the budget as `time.Duration.String()`: for example `response wait exceeded 10m0s`, `30m0s` for an explicit 30 minutes, `2s`.

### Parallel tool calls (provider default)

No request option controls parallel tool calls: the provider's own parallel-call behavior is preserved and no `parallel_tool_calls` or `disable_parallel_tool_use` field is sent on any route. Every call returned in a batch is executed, including calls after a terminal call.

### Named provider tool choice (Go library)

`provider.Request.ToolChoice string` is a library-only option: no task JSON field, CLI flag or loop option exists, and thinking and every other request field are unchanged. A nonempty value names the one tool the provider must call for this request at the API level (for example `submit`). `provider.SupportsToolChoice(provider.Role) bool` reports whether the role's route can do that.

- Empty (the default) sends today's exact request bytes on every route, including the existing automatic `tool_choice` fields; it adds no choice.
- With tools, the Responses wire (ChatGPT, SuperGrok) sends `tool_choice: {"type":"function","name":"submit"}` and the Chat Completions wire (OpenCode Go, OpenAI-compatible) sends `{"type":"function","function":{"name":"submit"}}`; any other name uses the same transformation. The name is not checked against `Tools`. Without tools no `tool_choice` is sent, as before; an unsupported route still refuses.
- Support follows the effective wire and profile settings after profile resolution, exactly as rendering does. Current Anthropic Messages profiles use adaptive thinking, which does not permit a forced tool: `SupportsToolChoice` reports false. Unknown providers report false. A Messages profile with thinking disabled would encode `{"type":"tool","name":"submit"}`; none exists today.
- An unsupported route refuses a nonempty `ToolChoice` in `Render` and `Respond` with `provider/unsupported_capability`, exit 4, a detail naming `ToolChoice` and the route (for example `Messages route anthropic`), before any credential lookup, network call or attempt record. It is never silently ignored or weakened.

### Cache breakpoints (fixed)

The Messages wire (Anthropic) places three default cache breakpoints: the last tool, the system block and the newest message. Each is the default five-minute lifetime (`{"type":"ephemeral"}`, no explicit `ttl`). No request option adds, moves or removes one.

### Process-group sweep and foreign-kill refusal (Go library)

`sys.Options.KillGroupOnExit` (default false): after the command's leader has ended,
`Session.Run` sends SIGTERM to its process group, polls like `Terminate` and sends
SIGKILL to what remains; it returns when the group has no member. It never sets
`TimedOut`, changes `Status` or `Output` or adds an error, and adds no default timeout.
The sweep does not reach a process that left the group (`setsid`, own-session
`nohup`, double-fork daemons, Gradle-style daemons). Group kill is not a sandbox.
The `shell` tool does not set it: its background servers survive between calls, and
the round's custody ends them when the round ends, whatever its outcome (L6).

`sys.Options.RefuseForeignKill` (default false) makes `Run` call
`ForeignKill(command, s.Owned)` before starting anything. A refusal starts nothing,
records no group and returns `Result{Status: 126, Output: RefusalText(rule), Rule: rule}`
with a nil error. Rule ids: `pkill-killall`, `kill-foreign-pid`. `Session.Owned(pid)` is
true for a pid or group in `Groups()` or a live descendant of one. The `shell` tool
enables it and returns exactly `RefusalText(rule)` as tool text; the session's
`tool.result` event gains `"rule"` only for a refused call. `ForeignKill` is a text
filter that stops the model's habit, not a bypass: `eval "$(echo ... | base64 -d)"`,
`sh -c "$VAR"`, `python -c 'os.kill'`, `find -exec kill`, a script file containing
`pkill`, `busybox killall` and computed ids pass.

Claude Code executor (Kogen side): Kogen kills `claude`'s group on cancel, Close and
round end. A blocking PreToolUse hook on the `Bash` matcher using `ForeignKill` is
possible but unverified and belongs to a separate item, K-SAFE-2. Kogen cannot see or
stop what `claude` runs between hooks, or processes that leave the group.

### Root-contained reads

`read_file`, `view_image` and the optional `path` of `list_files` and `search_text` are confined to `tools.Tools.Root` (default path: the root). `~` and `~/...` are refused, not expanded. Absolute paths outside the root, parent escapes and symlinks that leave the root at any component (leaf or intermediate, relative or absolute target) are refused too, with tool text `error: <path>: <reason>` and no outside payload; `Tools.Run` still returns a nil Go error. Relative and absolute paths inside the root work, as do file and directory symlinks whose destinations stay inside it, and a `Root` that is itself a symlink. Symlinks are followed before a later `..` is applied, containment compares path components (not string prefixes), and the file is opened through `os.Root` on the canonical root. This is source-path containment, not a shell sandbox: `shell` and probe commands, documentation URLs, provider credential loading, transcript paths and `write_file` are unchanged, and no credential-specific denylist exists inside the root. There is no option to disable it.

### Shell time limit

`tools.Tools` has no per-call shell time limit: shell calls are unbounded, the
`shell` definition says `Commands have no time limit.`, and output is exactly
`exit status: <n>\n<combined output>`. No task field, CLI flag, environment setting
or option adds one. `deadline_seconds` remains the standalone whole-round stopping
deadline.

`func (t *Tools) Definition(name string) (map[string]any, bool)` returns the same
definition as the package function `tools.Definition`, so callers may build
definitions from the instance they pass to the round; the engine still sends
supplied definitions verbatim. `tools.Definition` and `tools.Defs` are byte-identical
to their goldens.

`Tools.RunContext` and `CallContext` forward their context to shell commands
(`sys.Session.RunContext`): a done context starts no shell, and a shell that is
starting or running has its process group terminated and joined before the call returns
`ctx.Err()`; that is a stopping error, never tool feedback. `Run` and `Call` are
nil-context wrappers that never stop a shell this way. Groups that finished shells left
behind are ended by the round's custody (L6), not by the call.

The lower-level `sys.Options.Timeout` and `sys.Options.Context` remain independent
`sys` options with the custody rules below. `Options.Context` still only cancels a
fired positive-timeout custody wait; the execution context is `Session.RunContext`'s.

Observation is in-process: Darwin uses numeric KERN_PROC_PGRP actual data length
(including zombies), and Linux follows this rule. Linux first uses `kill(-pgid, 0)` as a monotone presence witness: success or `EPERM` means the group is present, with no readable `/proc` needed, and `pgid <= 1` is rejected before any kill. `ESRCH` alone never proves absence: Linux then enumerates `/proc` (zombies, state Z, included) and reads the group after the final `)` of each `stat`. Entries that vanish (`ENOENT`/`ESRCH`) are skipped; unreadable entries (`EPERM`/`EACCES`) and malformed `stat` are remembered, and a later membership witness wins over them. Without a witness, any remembered error or listing failure is an observation failure; only `ESRCH` plus a complete error-free scan with no member is absent. A `hidepid=1`/noaccess mount makes final confirmation fail rather than report absence; with `hidepid=2` (invisible) a hidden live member still cannot become absent because kill is a presence witness. Status as of 27 October 2026: research had reproduced the `ESRCH` defect on Linux; this correction was source-qualified on Darwin and cross-built, with Linux runtime proof pending at delivery. A cross-build does not prove lifecycle behavior. Other platforms explicitly lack native observation support.
A failed or unsupported observation returns `sys.Result{}` with an error matching
`errors.Is(err, sys.ErrTimeoutObservation)` (`timeout custody observation failed`),
including positive-timeout `sys` callers with no Context. Timeout signals are dispatched
independently and teardown is joined unless interruption/context takes precedence.
This is never `error:` feedback or an ending. A slow observation cannot delay
SIGTERM/SIGKILL or stop selection; ordinary successful observation can continue
waiting for an owned zombie to be reaped. A live PID outside the group does not
hold custody. No wall cap or retry budget is added.

A multi-round conversation is the caller's: after a terminal call, the next round's input appends `tools.OutputItem(terminal.CallID(), feedback)`. After a no-call ending it appends a user message `{"role":"user","content":feedback}`. `loop.Session` (below) does this for standalone callers.

```go
// Session is a standalone multi-round conversation with optional transcript persistence.
type SessionConfig struct {
    Root         string
    Role         provider.Role
    Instructions string   // "": DefaultInstructions
    Enabled      []string // generic tools; default read_file, write_file, list_files, search_text, shell
    Protected    []string // write_file refuses these paths (prevention only; not detection)
    Excluded     []string
    Terminal     []string // default ["finish"]
    Dir          string   // transcript directory ("" = in memory)
    Client       *provider.Client
    Session      *sys.Session
    Emit         func(api.Event) // event sink (nil: discard)
}
func NewSession(cfg SessionConfig) (*Session, error)
func ResumeSession(cfg SessionConfig) (*Session, error) // loads Dir/session.json; refuses mismatch (protocol, role, instructions/definitions digest)
func (s *Session) Round(ctx context.Context, text string) (Result, error) // first: opening user message; later: feedback per the rule above
```

## 3. Process protocol (`kogen-loop/v1`)

### Commands

- `kogen-loop capabilities --json` prints one `api.Capabilities` object. It needs no network or credentials.
- `kogen-loop run --task FILE|-` reads one `api.Task` (strict JSON: unknown fields refused) and runs **one round**. It writes JSON Lines `api.Event`s to stdout, nothing else. Diagnostics go to stderr.
- `kogen-loop version` prints the module version/digest line.

### Task (`api.Task`)

```json
{
  "protocol": "kogen-loop/v1",
  "root": "/abs/working/dir",
  "role": {"provider": "chatgpt", "model": "gpt-6.1-sol", "effort": "medium", "base_url": ""},
  "instructions": "",
  "prompt": "what to do (first round) or feedback (resumed round)",
  "tools": ["read_file", "write_file", "list_files", "search_text", "shell"],
  "protected": [], "excluded": [],
  "terminal": ["finish"],
  "deadline_seconds": 0,
  "session": {"dir": "", "resume": false},
  "requires": []
}
```

`requires` lists capability names the caller depends on (for example `"session_resume"`). A missing capability fails before any request with `loop/unsupported_capability`.

### Events (`api.Event`)

Every line has `protocol`, `seq` (1-based, gapless), `time` (RFC 3339 UTC) and `type`. Types in v1:

| type | fields |
|---|---|
| `session.started` | `session_id`, `resumed` (bool), `role`, `capabilities_digest` |
| `request.started` | `n`, `owner`, `model`, `effort` |
| `request.attempt` | `n`, `record` (the provider observer record, credentials never included) |
| `response` | `n`, `response_id`, `usage` (`api.Usage`) |
| `tool.call` | `call_id`, `name`, `arguments_sha256` |
| `tool.result` | `call_id`, `name`, `result_sha256`, `bytes`, `cut` (bool), and `rule` only for a refused shell call. `bytes` and `result_sha256` describe what the model received, after the cut. |
| `round.ended` | `ending` (`terminal`/`no_call`), `terminal_tool`, `claim` (terminal arguments or final text — `output_text` and `refusal` parts in content order, newline-joined — bounded 16384 bytes; **a claim, not proof**), `requests`, `usage` (round total) |
| `error` | `class`, `reason`, `detail` (same shape as `sys.Error`) |
| `session.ended` | `status` (`ended`/`failed`/`interrupted`), `exit` |

`session.ended` is always the last line. Callers must ignore unknown fields and unknown event types inside the same major version.

### Usage (`api.Usage`)

`{"input": n|null, "cached": n|null, "output": n|null, "reasoning": n|null, "state": "complete"|"partial"|"unknown", "source": "provider"}`

`state` is computed over these four categories. Inconsistent provider usage becomes all `null` with `unknown`. A round total is `null` for a category as soon as one response lacks it.

### Exit codes

| code | meaning |
|---|---|
| 0 | the round ended (`round.ended` emitted) |
| 1 | runtime or provider failure, including a missing sign-in (`error` emitted) |
| 2 | invalid task, unsupported protocol or capability, missing transcript, `session_mismatch` |
| 130 / 143 | interrupted by SIGINT / SIGTERM (`session.ended` status `interrupted`) |

### Control

- SIGINT or SIGTERM cancels the round, terminates all tool process groups (L6) and exits.
- `deadline_seconds` > 0 bounds the whole round. Expiry is `error` `loop/deadline` with exit 1.
- stdin carries only the task (`--task -`). There's no interactive control channel in v1.

### Session resume (capability `session_resume: "transcript"`)

With `session.dir`, the loop writes `session.json` atomically (0600, directory 0700) **after each completed round**:
`{protocol, session_id, role, instructions_sha256, definitions_sha256, terminal, input}`. `terminal` is `{"call_id", "name"}` of the last round's terminal call, or `null` after a no-call ending. The provider cache/routing identity is always the `session_id`, so it survives a resume; existing provider length normalization still applies. A standalone `Session` answers every unanswered call id of the previous round with the feedback.

`resume: true` loads it, refuses any mismatch (`loop/session_mismatch`), and runs one more round with `prompt` as feedback (rule in §2). A crash inside a round resumes from the last completed round. Tool effects after that boundary are the caller's to inspect: the loop doesn't replay or undo them. This standalone transcript is **not** Kogen's checkpoint format. Kogen keeps its own custody through hooks.

## 4. Capabilities (`api.Capabilities`)

```json
{
  "protocol": "kogen-loop/v1", "library": "loop/v1", "version": "<digest or dev label>",
  "providers": ["chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"],
  "tools": ["read_file", "write_file", "list_files", "search_text", "shell", "view_image", "documentation"],
  "terminal_default": ["finish"],
  "session_resume": "transcript",
  "context_policies": ["fail_over_budget"],
  "usage": "provider",
  "images": true,
  "subagents": false,
  "compaction": false
}
```

`false` and missing capabilities are real absences, not hidden equivalents. Subagents, compaction, alternative read/edit tools and review/build mechanisms are future experiments behind `HandleCall` and tool registration. Defaults don't change without scoped evidence.

## 5. Errors

Typed `sys.Error{Class, Reason, Detail, Exit}`. Provider errors keep their existing classes and texts (moved from Kogen). New loop classes:
- `loop/context_budget_exceeded`
- `loop/deadline`
- `loop/unsupported_capability`
- `loop/session_mismatch`
- `loop/invalid_task`
- `loop/unsupported_protocol`

## 6. Versioning and compatibility

- **Additive changes in v1** (new optional task field with a safe default, new event type or field, new capability) need a contract note in this file and a conformance fixture. Callers ignore unknowns.
- Native Anthropic Messages terminal `invalid_response` attempts optionally carry
  `provider_failure` in the attempt record and typed error. Its string-enum
  `anthropic_invalid` category may have one of `error_type`, `stop_reason`,
  `block_type`, or `delta_type`; unrecognized or ill-typed values are `unknown`.
  These allowlisted values contain no provider messages or payloads. A null
  `ttft_ms` does not prove no first token (non-streaming reads and streams without a
  parsed delta report null), and unknown `usage_state` does not
  prove no processing. A false failed end-turn/tool-use marker does not identify
  the cause. Diagnostics do not change retry or validity decisions.
- Every provider attempt record also carries stream observations, in integer
  milliseconds relative to that attempt's own start and reset on each retry:
  `headers_ms` (after the client's successful Do), `first_byte_ms`, `last_byte_ms`,
  `ttft_ms` (the first parsed Responses `*.delta` or Messages `content_block_delta` /
  `message_delta` event), `max_gap_ms`, `gap_hist` (six counts of gaps between
  consecutive positive-byte reads: [0,1s], (1s,10s], (10s,30s], (30s,60s], (60s,120s],
  over 120s), `stream_bytes` and `end_reason` (`complete`, `transport`, `cancel`,
  `budget` or `idle`, with the precedence of the transport-failure path; a stream cut
  before its completion is `transport` even where the parser reads EOF as the end).
  `idle` marks an attempt ended by the first-byte or idle timeout (see Client response
  budget), on every route including Chat Completions. Missing observations are null.
  Chat Completions and error-body reads set only `headers_ms` and `last_byte_ms`. The
  observations themselves change nothing; the only enforcement is the per-attempt
  first-byte and idle timeout above, and requests, budgets and results are unchanged.
- **Breaking changes** (removed or renamed field, changed meaning, changed engine order, changed default behavior) need `kogen-loop/v2` and `loop/v2`, and consumers must migrate deliberately.
The external reference described a Kogen-owned synchronized copy at
`cli/third_party/kogen-loop/`, a `replace` directive, sync script and
`cli/loop-pin.json` digest checks. That is historical integration context, not
implemented machinery or a verified current consumer/pin in this repository.
Kogen-side synchronization and pin updates remain outside this component's scope.

## 7. Conformance

`conformance/` holds recorded fake-provider exchanges and expected event sequences. A change that alters an expected sequence must update the fixture in the same reviewable change and say why. Required cases:
- terminal ending;
- no-call ending;
- multi-call batch with terminal in the middle (later calls still run; terminal output not appended);
- handled call;
- hook error stops the round;
- tool result cut;
- over-budget refusal;
- deadline;
- interruption with a running shell child (group terminated);
- strict task refusal;
- `requires` refusal;
- transcript resume and mismatch refusal;
- usage `unknown` preserved as `null`.

## Tool result cut (fixed)

The engine cuts a text tool result it delivers to 16384 UTF-8 bytes including the omission marker: it keeps the first 4096 bytes and a suffix, each backing off an incomplete UTF-8 character, around an `\n[... N bytes omitted ...]\n` marker counting the bytes actually absent. Fitting text is verbatim, cutting is idempotent and typed Output passes unchanged. Package `Cut(string)` and `Output.Cut()` apply it; there is no option to change the bound or the head. `Run`/`Call` return raw results; the engine applies the cut where it delivers a result it executed. Standalone sessions, replay, definitions and typed images are unchanged.

## Documentation byte bounds (fixed)

The documentation tool fits body and sources to a 16384-byte encoded JSON target (not runes or body length); unusually large query, URL or operation metadata can exceed that target, as in the unchanged default behavior. It reads at most the first 8388608 bytes of one response body, a prefix with no oversize error. Neither is configurable; `tools.Documentation` has `UserAgent`, `Timeout` (20 s default) and `PublicSearch` only. Fitting keeps the existing order (body halves, sources drop last-first, the untrusted marker stays). The engine's 16384-byte result cut applies to every delivered result.

## Ranged documentation reads (Go tools only)

A documentation `fetch` accepts optional `offset` (integer) and `find` (string). `offset` is a byte index into the decoded body (after the 8388608-byte body prefix and UTF-8 repair); an interior UTF-8 position moves back to its rune start, a negative offset is zero and one past the end is the end. An empty `find` is absent. `find` is case-insensitive: among matches at or after the normalized offset the first Markdown ATX heading line wins, otherwise the first text match; the body starts at that line's beginning (never before the offset). Original byte coordinates are kept. No match is the ordinary status `not_found` with an empty body, a short `error` note, the correct `body_total`, the source URL, `untrusted` true and no `next_offset`.

Every fetch outcome reports `body_total`, the decoded body bytes (zero when no body was retrieved). A ranged fetch (`offset` or `find` given) also reports `body_offset`, the source byte where `body` starts. `next_offset`, present only when source remains after fitting, is the first unconsumed source byte (`body_offset` plus the source bytes emitted); the synthetic untrusted marker consumes no source bytes. Pass it as `offset` for the next call; each call is one independent fetch, nothing is cached and no limit, timeout or retry changes.

Exception: a plain fetch (no `offset`, no `find`) returns exactly the body bytes it always did and adds only `body_total` and, when truncated, `next_offset`; it never reports `body_offset`. Search output is unchanged.
