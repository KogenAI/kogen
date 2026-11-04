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
- **L6 Process custody.** Shell tools run in their own process groups. Cancellation, deadline or interruption terminates every group the loop started (SIGTERM, then SIGKILL after a bounded wait) before the call returns, including a shell that is still starting or is registered late. Every round also ends its own groups when it ends in any way (a terminal call, a no-call answer, a hook or requester error as well as cancellation, deadline or interruption), background processes included; they stay alive between the round's calls. Groups started before the round and processes that left their group (`setsid`, daemons) are not touched. A host binary calls `sys.MaybeSupervise(os.Args[1:])` and `sys.EnableSupervisor()` first in `main`, as Kogen does. `cmd/kogen-loop` does so too, so a killed host still takes its command groups down: the supervisor finishes the whole-group SIGTERM-then-SIGKILL escalation even when the direct shell exits on SIGTERM and a descendant ignores it, and a shell that already ended leaves a small keeper in its group while members remain, so a killed host still stops them. A library caller that skips this keeps only the in-process termination.  Shell calls yield after 45 seconds without killing the command.

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

// Direct is the provider-backed Requester (provider.Client.Respond). A request that fits is
// sent unchanged; an over-budget one is condensed first (see "Input window budget"), and one
// that cannot be made to fit is refused (typed error loop/context_budget_exceeded) before
// sending, never clipped. It takes an optional provider.Observer for attempt records.
type Direct struct {
    Client    *provider.Client
    Session   *sys.Session
    Observer  provider.Observer  // nil: none
    CacheID   string             // one cache identity per conversation (kept across rounds)
    Cache     *provider.Cache
    Condensed func(Condensation) // nil: none; told of each condensation before the request is sent, and once of a failed one (Failed true)
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

**Overlap without response or call hooks (normative).** Steps 3 and 5 above are the order of a round with an `AfterResponse`, `BeforeCall`, `HandleCall` or `AfterCall` hook: the complete validated response first, then the calls serially, each hook seeing the outputs before it. When none of those four hooks is installed (`BeforeRequest` alone does not count) the engine does not wait for the whole response and does not run the calls one by one. This is the default and has no option, flag or field:

- A streamed call becomes eligible only when its name, id, arguments and position are complete and valid for the provider adapter: Responses at `response.output_item.done`, Messages at `content_block_stop` after the tool input is assembled. Argument fragments never execute. A Chat Completions answer (read whole) and any `Requester` that only returns completed responses dispatch their calls only after the response is validated, under the same rules. The completed response stays the authority: a call started early is kept only if it is the response's call at the same position, otherwise its work is cancelled and joined and the response's calls run.
- Calls keep their original order for dependencies. A call starts only when every earlier stream position is complete and no earlier unfinished call can conflict with it. Native reads (`read_file`, `list_files`, `search_text`) overlap each other; `view_image` reads the whole tree (its candidate metadata). Writes to different files, resolved through `..` and symlinks (case-insensitively), overlap each other and unrelated reads; a write that equals, contains or is contained by another call's read or write target serializes. `list_files` and `search_text` read both the resolved path and the path Git receives. A write outside the root, into `.git` or to a `.gitignore` or `.gitattributes` file changes what Git shows, so it is a barrier, and so is a `read_file` path through `..` that does not exist yet. `shell`, `probe`, `documentation`, disabled or unknown names, malformed arguments and any path that cannot be resolved are barriers against every other call: arbitrary shell commands are never parsed for safety and stay in order. Terminal calls are not executed and do not drop later calls; the last terminal call still wins.
- Results and the conversation stay in original call order whatever order the calls finish in. A response is published (replay and outputs appended, the next request started) only when it validated and every call finished. A failed attempt cancels and joins its running calls and discards its staged results before the provider's existing retry wait; retries, backoffs and limits are unchanged. A tool stop, cancellation or deadline cancels and joins every running call before `Run` returns; the first error is returned unchanged and no partial result reaches the conversation, `Result` or a transcript. Writes already made are not rolled back. Every process group the round started is still ended before `Run` returns, including those of a shell that was starting.

Cancellation observed after a response/call hook returns nil stops the round
before executing a tool, starting another request or returning an ending. A hook error still
takes precedence and is returned unchanged.

### Input window budget (fixed) and condensation

The complete rendered request (instructions, tools, cache placement) is measured inclusively against a fixed 524288-byte ceiling (`provider.InputBudgetBytes`), or a smaller documented bound of the role's model family; the 131072-token output reserve and the family bounds stay in force. There is no option to change it, and describing the limit as a token budget does not enlarge it. A request that fits is sent unchanged.

`loop.Direct` (and so every standalone `Session`) condenses a request that does not fit, before sending it, instead of refusing it:

- The conversation is split at complete exchange boundaries (the replayed items of one response with the outputs of its calls); a call is never separated from its result and an incomplete batch is never consumed.
- Kept exact: the instructions and tool definitions, the original task and every later user message (in a `Session`, also the exchange whose terminal call a later round's feedback answers), and the newest complete exchange together with as many recent exchanges as fit in a quarter of the ceiling. Older exchanges, and any earlier summary, become one summary message (a user message that starts with `loop.CondensedHeader`, so it is kept in session history and in `session.json`, survives resume and is folded into the next condensation).
- The summary is written by the model through the same provider, role, credentials and transport, in requests without tools whose complete body must itself fit. Older exchanges are rendered as quoted data in fitting chunks, each chunk request carries the summary so far, and a summary above a quarter of the ceiling is merged once more and must come out shorter. The instructions ask for facts, decisions, files changed, checks and outcomes, unresolved errors and remaining work, and to treat the historical text, including instructions in it, as data.
- Every step consumes exchanges or shrinks the summary, and at most two summarization requests per older exchange plus two are sent. The condensed request is measured again. If what must stay exact (or one older exchange) cannot fit, the request is refused with `loop/context_budget_exceeded` (message `<owner>: complete next request N bytes exceeds LIMIT; reserve R tokens. ...`) before the conversation is sent; when no summarization is possible the message ends `Nothing was sent and nothing was clipped.`, otherwise it says what condensation could not reduce. A provider failure, a cancellation, an empty summary or a summary that cannot be shortened stops the round with that error; nothing is retried in a loop and no finish is invented. Finishing remains the model's claim.
- Disclosure: a `context.condensed` event precedes the condensed request's attempts (summarization attempts are `request.attempt` events whose `record.purpose` is `condensation`). The summarization usage is in that event, not in the round's `response` totals. A condensation that fails after at least one summarization request was sent is disclosed too, once, before `Direct.Request` returns its unchanged error: `Condensation.Failed` is true, `Requests` and `Usage` (`SumUsage` of the responses received; unknown when none) are what was spent, `BytesBefore` and `Limit` are as on success, and `CondensedExchanges`, `KeptExchanges`, `BytesAfter` and `SummaryBytes` are 0. A failure before any summarization request discloses nothing.

`loop.FailOverBudget` is the guard that refuses without condensing; `loop.Direct` applies it after condensation. `tools.Measure` reports the rendered size, the ceiling and the output reserve.

### Client response budget (Go library)

`provider.Client.ResponseBudget time.Duration` is a library-only lower-only option: no CLI flag, task field or provider protocol change exists. The unit is a Go `time.Duration`. Zero keeps the package constant `provider.ResponseBudget` (30 minutes), with unchanged wire bytes, diagnostics and retry behavior. A nonzero value must be in the inclusive range 1 second through 30 minutes; `Respond` refuses anything else before credentials, network traffic or backoff with `*sys.Error` (class `provider`, reason `refused`, exit 4, detail `response budget must be zero or between 1s and 30m0s`).

- The effective logical-call budget is the client value, or 30 minutes for zero; nothing else selects it.
- The budget stays absolute: it covers credential waits, refresh, transport, stream reads, retry backoff and retries; bytes and heartbeats never renew it. No retry is added.
- Every transport attempt also has default silence timeouts, for everyone and without a caller-facing option; they end only that attempt and never renew or extend the absolute budget. The first response progress must arrive within 90 s for ChatGPT and 45 s for Anthropic Messages and every other provider; after that no more than 180 s may pass between progress reads. Only response progress counts, not every byte. For streams (Responses, Messages) the first-progress clock starts at request dispatch and response headers do not meet it. A body read is progress when it completes at least one SSE event (a block ending in a blank line, LF or CRLF) that has a `data:` field and is not a keep-alive; an unfinished event counts in the read that completes it. Keep-alives are blocks made only of comment lines (`: keepalive`, `: ping`, ...) and blank lines and, on Messages, `ping` events (`event: ping` or a data object whose `type` is `ping`); they neither meet the first-progress limit nor renew the idle clock. Every other data event is progress, including Responses `response.created` and `response.in_progress`, error events and Messages events the parser ignores. A read of zero bytes is never progress. For a body read whole (non-streaming Chat Completions and every HTTP error body, on any route) the headers are the first progress and start the idle clock, and a body read renews it only when it has a byte other than JSON whitespace (space, tab, LF, CR). Elapsed time is read from `Client.Now`; a blocked header wait or body read is cancelled when its limit passes rather than waiting for another byte. Progress strictly before the limit is valid; at the limit the attempt has expired.
- An expired attempt is a transient failure (outcome `failed`, `end_reason` `idle`, also on Chat Completions) whose detail is `no first byte within 90 s`, `no first byte within 45 s` or `stream idle for 180 s`. It is retried by the existing attempt policy with unchanged count and 2 s/8 s backoff (it has no `Retry-After`), and is single-shot with `Request.Single` on ChatGPT. The absolute budget and caller cancellation take precedence over an overlapping timeout. Request bytes are unchanged.
- Visible output limit (fixed, not an option; every caller and the CLI): one transport attempt on a streaming wire (Responses for ChatGPT and SuperGrok, Messages for Anthropic) may carry at most 131072 bytes (128 KiB) of visible output; exactly 131072 is allowed, 131073 or more ends the attempt. The count starts at zero for every attempt, retries included. It is the UTF-8 byte length of the decoded JSON string in completed SSE data events: on Responses the `delta` of `response.output_text.delta`, `response.refusal.delta` and `response.function_call_arguments.delta`; on Messages the `delta.text` of a `content_block_delta` with `delta.type` `text_delta` and its `delta.partial_json` with `input_json_delta`. A missing or non-string delta counts 0. Reasoning (`response.reasoning_text.delta`, `response.reasoning_summary_text.delta`, `thinking_delta`, `signature_delta`), every `*.done` event, `response.output_item.done` items and the output of `response.completed` (they repeat counted text), keep-alives, comments, framing, any other event and an unfinished event do not count. The event whose delta pushes the total above 131072 ends the attempt at once: no later event is applied or delivered early, even a `response.completed`, `message_stop` or failure event in the same read, and the response body is closed. The result is a transient failure with the detail `visible output exceeded 131072 bytes`; the attempt record (the `record` of the CLI's `request.attempt` event and of every `provider.Observer`) has outcome `failed`, error `provider_failure`, `end_reason` `output_limit`, unknown usage and no `provider_failure` diagnostics, and `stream_bytes` still counts every byte read. The existing failed-attempt behavior then applies unchanged: calls started early in that attempt are aborted and nothing is staged, and the request is retried, at most 3 transport attempts with 2 s then 8 s backoff (a stream carries no `Retry-After`). A third cut ends the call as `provider/unavailable` (exit 4), detail `<Label> did not answer after 3 attempts: visible output exceeded 131072 bytes`, for example `ChatGPT did not answer after 3 attempts: visible output exceeded 131072 bytes`; with `Request.Single` on ChatGPT there is one attempt and the detail is `visible output exceeded 131072 bytes`. The CLI then emits the `error` event `{class: provider, reason: unavailable, detail: ...}` and `session.ended` status `failed`, and exits 1. The absolute budget and caller cancellation keep their precedence and the budget is never renewed. The non-streaming Chat Completions wire (OpenCode Go, openai-compatible) is unchanged, as are the 64 MiB `streamLimit`, the silence limits, the retry counts and the request bytes (no `max_output_tokens` is sent).
- A transient failure that will be retried (attempt 1 or 2) waits for the answer's `Retry-After` instead of the 2 s/8 s backoff when it has a usable one, on every HTTP route (Responses, Chat Completions, Messages). Usable means HTTP status exactly 429 or 503 and a first `Retry-After` value, trimmed of spaces and tabs, in one of the two RFC 9110 forms: delay-seconds (ASCII digits, leading zeros allowed; `0` retries at once) or an HTTP-date (`net/http.ParseTime` formats; the wait is the date minus `Client.Now`, 0 when not in the future). Anything else (empty, negative, fractional, text, an unparsable date, other statuses, stream failure events, other headers such as `retry-after-ms`) is absent and keeps the 2 s/8 s schedule by position. The advertised wait is used exactly, shorter or longer than the schedule, and still counts against the absolute budget and yields to cancellation. The maximum is a fixed 60 s, inclusive: a usable `Retry-After` above it ends the call at once, with no wait and no further request, as `provider/unavailable` (exit 4, with the attempt's diagnostics), detail `<Label> asked to wait <N> s before retrying, more than the 60 s limit: <attempt detail>`, where `<N>` is the delay-seconds digits without leading zeros (kept as text) or an HTTP-date's wait rounded up to whole seconds. The attempt count does not change: at most 3 transport attempts, and the third transient failure ends with `<Label> did not answer after 3 attempts: <attempt detail>` whatever `Retry-After` it carries. The unreadable-answer retry, the 401 refresh, the cache-key strip retry and `Request.Single` are unchanged. No option selects any of this.
- A connection failure is an attempt whose HTTP exchange returned an error that contains a `*net.OpError` with `Op` `dial` (connection refused, the dial i/o timeout, an unreachable network or host, a failed name lookup): nothing reached the provider. The caller's interrupt, the spent budget and the attempt's silence timeout keep their precedence and are not connection failures, and errors after a connection exists (TLS handshake, reset or EOF, body read errors, cut streams) are handled as before. The failed attempt itself is unchanged: transient, same detail, same record (outcome `failed`, error `provider_failure`, `end_reason` `transport` where the route records one, no `provider_failure` diagnostics), one of the 3 attempts. When it is attempt 1 or 2, the usual 2 s/8 s backoff comes first (it has no `Retry-After`) and then the run waits until the origin accepts a TCP connection before the next attempt: one direct TCP connect (`net.Dialer`, not `Client.HTTP`) to the host and port of the origin the attempt was sent to (the port from the URL, else 443 for `https` and 80 for `http`), closed at once without writing a byte; each probe lasts at most 5 s (and at most the remaining budget), and after a failed probe the run pauses 1 s (clipped to the budget) and probes again. The first connected probe ends the wait and the next attempt is sent at once. The wait sends no request, no HTTP or TLS and no credentials, emits no attempt record or event, and is neither an attempt nor a retry (the L3 round limit is unaffected). Only a connection, the absolute response budget (`response wait exceeded ...`) or the caller's cancellation, interruption or deadline end it. The attempt count does not change: a connection failure on attempt 3 ends the call with `<Label> did not answer after 3 attempts: <attempt detail>` and no wait, and every failure after the wait follows the existing rules. `Request.Single` is unchanged: one attempt, no wait. No option selects any of this.
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

**Printed paths.** `list_files` and `search_text` print every path as the file system spells it, so it can be passed unchanged to `read_file` and the other file tools. Git's own octal quoting (`"caf\303\251.txt"`) is not used. A path is printed verbatim when it is valid UTF-8, every rune satisfies Go's `strconv.IsPrint` (letters, marks, numbers, punctuation, symbols and the ASCII space) and it does not start with `"`: non-ASCII names, spaces, a backslash or `"` that is not the first byte and trailing spaces stay as named. Any other path (a control character such as newline or tab, invalid UTF-8, a non-printable rune such as U+00AD, or a leading `"`) is printed as `strconv.Quote(path)`, a Go double-quoted string literal such as `"line\nbreak.txt"` or `"caf\xe9.txt"`. So a printed path that starts with `"` is always the quoted form, `strconv.Unquote` gives the exact name, any other printed path is the exact name, and a quoted path never holds a raw newline: each path occupies one line. The file tools do not accept the quoted form; they take the decoded name. Routes: `list_files` runs `ls-files -z --cached --others --exclude-standard --deduplicate -- [pathspec]`, reads the NUL-terminated names and joins the rendered names with `\n` in Git's order, without trimming white space (a last name that ends in a space keeps it); empty output is `(no files)`. `search_text` compiles the pattern, cut at its first NUL byte, with Go's `regexp.Compile` (RE2 syntax, case-sensitive, no flags), so `\b`, `\d`, `\s`, `\w`, alternation and classes mean the same on every host; a pattern RE2 cannot express (a backreference, a lookaround, `\Z`) returns `error: invalid pattern: <reason>` (the Go error's text without its leading `error parsing regexp: `, for example ``error: invalid pattern: missing closing ): `(` ``) without running Git, after the argument and path checks. It then runs `grep -z -n -I -E --untracked -e "" -- [pathspec]` (the empty pattern lists every line of every searched text file), parses each record `<path>NUL<line number>NUL<text>LF`, keeps the records whose `<text>` (the line without its LF) the pattern matches, and prints `<rendered path>:<number>:<text>` lines joined with `\n`, with trailing white space of the whole result trimmed as before; status 1, or no kept record, is `(no matches)`. Each is still exactly one `Tools.Repo.Run` call; a caller-supplied `Tools.Repo` receives the extra `-z` argument through the same `Git.Run`. Unchanged: inclusion rules (tracked and untracked files, not ignored ones), Git's order, deduplication, root containment, pathspec handling, error texts and classes, and the 16384-byte bound at delivery. The `Snapshot` listing shows the same text, and its `read_file` headers still use the Go-quoted real path.

`read_file`, `view_image` and the optional `path` of `list_files` and `search_text` are confined to `tools.Tools.Root` (default path: the root). `~` and `~/...` are refused, not expanded. Absolute paths outside the root, parent escapes and symlinks that leave the root at any component (leaf or intermediate, relative or absolute target) are refused too, with tool text `error: <path>: <reason>` and no outside payload; `Tools.Run` still returns a nil Go error. Relative and absolute paths inside the root work, as do file and directory symlinks whose destinations stay inside it, and a `Root` that is itself a symlink. Symlinks are followed before a later `..` is applied, containment compares path components (not string prefixes), and the file is opened through `os.Root` on the canonical root. This is source-path containment, not a shell sandbox: `shell` and probe commands, documentation URLs, provider credential loading, transcript paths and `write_file` are unchanged, and no credential-specific denylist exists inside the root. There is no option to disable it.

### Shell time limit

A shell call supplies exactly one string `command` or `handle`. A new command waits at most 45 seconds; retrieval waits at most 30 seconds. Both return
immediately on completion without imposing an execution timeout. Fast commands return `exit status: <n>\n<combined output>`.
Running commands return JSON with `status: "running"`, an opaque `handle` and cumulative
`output`. Retrieval returns that shape or `status: "completed"` with the same handle,
integer `exit_status` and cumulative output. Completed retrieval is repeatable until round
end. Invalid combinations and unknown or expired handles return `error:` text. Output is
bounded inside the JSON envelope. Round cleanup stops yielded groups. The wait is not a
setting; `deadline_seconds` remains the whole-round deadline and `sys.Options.Timeout` is independent.
`Tools.ShellAfter` is a test seam: when set, a shell call passes it the wait it would otherwise take and treats a value from the returned channel as that wait elapsing; production leaves it nil.

The `tool.result` event of a shell call that reaches its wait (a well-formed call with a known handle or a started command, in a live context) carries `shell_wait`, a JSON object with exactly four keys: `spawned` (the instant the command's process started, or `null` while none had started when the wait ended: a refused command, one that failed to start, one still starting), `wait_started` and `wait_ended` (the instants this call's bounded wait started and ended), and `ended_by`: `exit` (the call returns a completed result), `handle_yielded` (a new command's 45-second bound elapsed and a handle was issued) or `bound` (a retrieval's 30-second bound elapsed, same handle). When completion and the bound are both ready, `ended_by` follows the returned result. An instant is RFC 3339 UTC with exactly nine fractional digits (`2006-01-02T15:04:05.000000000Z07:00` applied to `t.UTC()`) and is a wall-clock instant of the kogen-loop process, so it compares with the event `time`. A retrieval repeats its command's `spawned`. Malformed calls, unknown handles, non-shell tools and calls without a `tool.result` carry none. `tools.Classified.ShellWait` (`*tools.ShellWait`, nil without a wait) returns the same record from `RunClassified` and `CallClassified`; `api.ShellWaitExit`, `api.ShellWaitBound` and `api.ShellWaitHandleYielded` name the endings. Nothing the model receives changes.

`func (t *Tools) Definition(name string) (map[string]any, bool)` returns the same
definition as the package function `tools.Definition`, so callers may build
definitions from the instance they pass to the round; the engine still sends
supplied definitions verbatim. `tools.Definition` and `tools.Defs` are byte-identical
to their goldens.

`Tools.RunContext` and `CallContext` forward their context to shell commands
during each wait: a done context starts no shell, and a shell that is
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
func (s *Session) Round(ctx context.Context, text string) (Result, error) // first: opening user message (plus the workspace snapshot of a small repository, see below); later: feedback per the rule above
```

**Workspace snapshot.** When a `Session` round starts with an empty conversation (the first round of `NewSession`, or a later round after rounds that all failed), the opening is the task text `{"role":"user","content":<task>}` followed by one more user message, the snapshot, computed before the first request by `tools.Tools.Snapshot()`. It is `tools.SnapshotHeader`, `\n\nlist_files:\n` and the `list_files` output (no arguments), then for every listed file shown `\n\nread_file <Go-quoted real path>:\n` and its `read_file` output, both as delivered to the model (after the 16384-byte bound); nothing follows the last section. A file is shown when `read_file` reads it, it is a regular file (in-root symlinks are followed), has at most 4096 bytes, no NUL byte and valid UTF-8; every other listed file appears in the listing only, and building the snapshot never waits on a FIFO. There is no snapshot, and the opening is the task alone, unless `list_files` and `read_file` are both enabled, `list_files` lists at least one path (not a non-Git root or an empty repository), at most 64 paths are listed and the shown files total at most 32768 bytes (never truncated). The snapshot becomes part of the conversation: it is carried once by every later request, written to `session.json` and kept exact by condensation. `ResumeSession` rounds and later rounds add none, and `loop.Run` never adds one. There is no option, event or field for it.

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
| `context.condensed` | `n` (the request it precedes), `requests` (summarization requests), `condensed_exchanges`, `kept_exchanges`, `bytes_before`, `bytes_after`, `limit`, `summary_bytes`, `usage` (`api.Usage` of the summarization requests; unknown stays null); `failed` (`true`) only on a condensation that failed after sending a summarization request, with `condensed_exchanges`, `kept_exchanges`, `bytes_after` and `summary_bytes` 0, emitted before the round's `error` |
| `tool.call` | `call_id`, `name`, `arguments_sha256` |
| `tool.result` | `call_id`, `name`, `result_sha256`, `bytes`, `cut` (bool), `rule` only for a refused shell call, `shell_wait` only for a shell call that reached its bounded wait (see [Shell time limit](#shell-time-limit)), `error_kind` only for a tool error and `malformed_class` only for a malformed call (see [Tool error kinds and malformed call classes](#tool-error-kinds-and-malformed-call-classes)). `bytes` and `result_sha256` describe what the model received, after the cut. |
| `round.ended` | `ending` (`terminal`/`no_call`), `terminal_tool`, `claim` (terminal arguments or final text — `output_text` and `refusal` parts in content order, newline-joined — bounded 16384 bytes; **a claim, not proof**), `requests`, `usage` (round total) |
| `error` | `class`, `reason`, `detail` (same shape as `sys.Error`) |
| `session.ended` | `status` (`ended`/`failed`/`interrupted`), `exit` |

`session.ended` is always the last line. Callers must ignore unknown fields and unknown event types inside the same major version.

### Tool error kinds and malformed call classes

A `tool.result` is an error when its delivered text starts with `error: ` or `refused: `. It then carries exactly one of `error_kind` (a well-formed call whose tool failed) or `malformed_class` (the call itself is wrong); every other result carries neither. Both are strings from the fixed vocabularies below (`api.ToolError*`, `api.Malformed*`), never the error text or the arguments, and nothing the model receives changes. Terminal calls have no `tool.result`; `exit status: N` texts, shell envelopes, `(no matches)`, `(no files)`, typed `view_image` parts and `documentation` results are not errors; `probe` has no category.

`malformed_class`:

| class | condition |
|---|---|
| `unknown_tool` | the name is not an enabled tool (unknown, or known but not enabled) |
| `missing_argument` | a required string argument is absent: `path` of `read_file`, `write_file` and `view_image`, `content` of `write_file`, `pattern` of `search_text`; a `shell` call with neither a non-blank string `command` nor a non-blank string `handle` |
| `wrong_argument_type` | that argument is present but not a string (JSON `null` included); a `shell` `command` that is not a string without a non-blank `handle`; a `read_file` `start_line` or `end_line` that is not a JSON integer or is too large to represent |
| `conflicting_arguments` | a `shell` call with both a non-blank string `command` and a non-blank string `handle`; a `read_file` `end_line` before its effective start |

Where a tool checks several arguments the class follows the one the text names (`write_file` checks `path` before `content`; `read_file` checks `path`, then `start_line`, then `end_line`).

`read_file` line ranges: a `start_line` or `end_line` that is not a JSON integer (a string, a number written with a fraction or an exponent, `null`, a boolean, an array, an object) returns `error: argument <name> must be an integer`, and a number too large to represent as a float64 (`1e999`) returns `error: argument <name> is a number too large to represent`; integers beyond int64 are still clamped. An `end_line` smaller than the effective start (`start_line` when at least 1, else 1) returns `error: end_line <end_line> is before start_line <start>` (`end_line 1` with `start_line 3` gives `error: end_line 1 is before start_line 3`), checked before the file is read. A `start_line` greater than the file's line count (a final newline ends the last line; an empty file has 0) returns the notice `(start_line <start> is past the end of <path>; line count: <N>)`, with `<path>` as given, and carries no error kind or malformed class; without `start_line` an empty file still returns an empty text. `tools.DecodeArguments` keeps an arguments object that holds a number too large for a float64, as a `json.Number` of its literal text.

`error_kind`:

| kind | condition |
|---|---|
| `not_found` | `read_file` of a path that does not exist |
| `is_folder` | `read_file` of a folder |
| `outside_root` | root containment refused the path of `read_file`, `view_image`, `list_files` or `search_text` (`~`, absolute outside the root, `..` escape, symlink leaving the root, top-anchored Git pathspec) |
| `file_error` | any other file-system failure of `read_file`, `write_file`, or resolving the path of `list_files` or `search_text` |
| `protected` | `write_file` refused a protected path |
| `git_failed` | the Git command of `list_files` or `search_text` failed or could not start, or the `search_text` pattern is not valid RE2 |
| `unknown_shell_handle` | a `shell` retrieval with an unknown or expired handle |
| `foreign_kill` | the foreign-kill filter refused a `shell` command (`rule` stays in the event) |
| `invalid_image` | `view_image` of a string path inside the root that is missing, not a regular file, outside the byte limits or not a supported PNG |

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

### Atomic `write_file`

`write_file` writes a temporary file next to the target (mode 0666 for a new file, subject to the umask; an existing regular file keeps its permission bits), checks the write and the close, and only then renames it over the target. A failed write leaves the previous bytes and removes the temporary file; the result is `error: <path>: <reason>`. An existing symlink is followed and remains a link. Nonregular targets (`eisdir`, `einval`) and files the caller cannot write (`eacces`) are refused without a change, as are paths named in `Tools.Protected` either directly or as the resolved destination (including dangling links). A protected refusal names the root-relative protected destination and occurs before creating directories or changing bytes. This protection does not confine writes to the root or guard against concurrent link changes. Because the replacement is a new inode, a hardlink alias keeps the previous bytes; this is not a filesystem sandbox, and no multi-file transaction or directory-fsync durability is promised. A file in a folder the caller cannot write to can no longer be replaced in place.

### Missing session

`loop.Direct.Request` and `provider.Client.Respond` refuse a nil `*sys.Session` with a `*sys.Error` of class `validation`, reason `missing_session` and detail `Session is required` (`validation/missing_session: Session is required`), before any credential is read or request is sent.

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
  "context_policies": ["condense_over_budget"],
  "usage": "provider",
  "images": true,
  "subagents": false,
  "compaction": true
}
```

`false` and missing capabilities are real absences, not hidden equivalents. Subagents, alternative read/edit tools and review/build mechanisms are future experiments behind `HandleCall` and tool registration. Defaults don't change without scoped evidence.

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
  `headers_ms` (after the client's successful Do), `first_byte_ms`, `last_byte_ms`
  (the latest positive read of any bytes, keep-alives included), `last_progress_ms` (the
  latest progress read of a stream, or the headers or latest read with a non-whitespace
  byte of a body read whole; null when none came, so on a streaming route null means no
  first progress), `ttft_ms` (the first parsed Responses `*.delta` or Messages `content_block_delta` /
  `message_delta` event), `max_gap_ms`, `gap_hist` (six counts of gaps between
  consecutive positive-byte reads: [0,1s], (1s,10s], (10s,30s], (30s,60s], (60s,120s],
  over 120s), `stream_bytes` and `end_reason` (`complete`, `transport`, `cancel`,
  `budget`, `idle` or `output_limit`, with the precedence of the transport-failure path; a stream cut
  before its completion is `transport` even where the parser reads EOF as the end).
  `idle` marks an attempt ended by the first-byte or idle timeout (see Client response
  budget), on every route including Chat Completions. `output_limit` marks an attempt
  ended by the visible output limit (see Client response budget). Missing observations are null.
  Chat Completions and error-body reads set only `headers_ms`, `last_byte_ms` and
  `last_progress_ms`. An attempt ended by silence shows `end_reason` `idle` with
  `last_byte_ms` and `last_progress_ms`. `stream_bytes` still counts every byte. The
  observations themselves change nothing; the only enforcement is the per-attempt
  first-byte and idle timeout and the visible output limit above, and requests, budgets and results are unchanged.
- Every provider attempt record also carries two keys read as the attempt starts, on every route and
  mode (completed, failed and cancelled attempts, `Request.Single`, condensation). `request_offset_ms`
  is an integer: the whole milliseconds from the request start to this attempt's start, on the
  `Client.Now` clock. The request start is the instant `Client.Respond` begins the call, the same one
  from which the response budget counts and the same for every attempt of the call; the attempt start
  is the instant of the record's `timestamp`. So time before the first attempt (a credential refresh)
  counts in the first offset, and a later attempt's offset includes the earlier attempts and every
  backoff, `Retry-After` and origin wait. `load_average` is the host's 1, 5 and 15 minute load averages
  in that order, a JSON array of three numbers each rounded to two decimals (`[9.82, 8.26, 7.69]`), read
  from `vm.loadavg` on darwin and `/proc/loadavg` on linux; it is `null` on any other platform and
  whenever the read fails, which never fails or delays the attempt. Nothing else in the record, the
  requests, retries, waits, budgets or results changes.
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
- over-budget refusal of an irreducible request, and condensation of a reducible one (`context.condensed`);
- deadline;
- interruption with a running shell child (group terminated);
- strict task refusal;
- `requires` refusal;
- transcript resume and mismatch refusal;
- usage `unknown` preserved as `null`.

## Tool result cut (fixed)

The engine cuts a text tool result it delivers to 16384 UTF-8 bytes including the omission marker: it keeps the first 4096 bytes and a suffix, each backing off an incomplete UTF-8 character, around a marker counting the bytes actually absent. When the head ends at a line boundary and the tail starts just after one, the marker is `\n[... L lines, N bytes omitted ...]\n` with `L` the complete lines omitted (`1 line` for one); when the text is numbered `read_file` text (every line `N<tab>` with consecutive numbers) it is `\n[... L lines (a-b), N bytes omitted ...]\n`, where `a`-`b` are the omitted line numbers, so `start_line=a`, `end_line=b` recovers them. Every other cut, such as inside one long line, keeps the byte-only `\n[... N bytes omitted ...]\n`. Fitting text is verbatim, cutting is idempotent and typed Output passes unchanged. Package `Cut(string)` and `Output.Cut()` apply it; there is no option to change the bound or the head. `Run`/`Call` return raw results; the engine applies the cut where it delivers a result it executed. Standalone sessions, replay, definitions and typed images are unchanged.

## Documentation byte bounds (fixed)

The documentation tool fits body and sources to a 16384-byte encoded JSON target (not runes or body length); unusually large query, URL or operation metadata can exceed that target, as in the unchanged default behavior. It reads at most the first 8388608 bytes of one response body, a prefix with no oversize error. Neither is configurable; `tools.Documentation` has `UserAgent`, `Timeout` (20 s default) and `PublicSearch` only. Fitting keeps the existing order (body halves, sources drop last-first, the untrusted marker stays). The engine's 16384-byte result cut applies to every delivered result.

## Ranged documentation reads (Go tools only)

A documentation `fetch` accepts optional `offset` (integer) and `find` (string). `offset` is a byte index into the decoded body (after the 8388608-byte body prefix and UTF-8 repair); an interior UTF-8 position moves back to its rune start, a negative offset is zero and one past the end is the end. An empty `find` is absent. `find` is case-insensitive: among matches at or after the normalized offset the first Markdown ATX heading line wins, otherwise the first text match; the body starts at that line's beginning (never before the offset). Original byte coordinates are kept. No match is the ordinary status `not_found` with an empty body, a short `error` note, the correct `body_total`, the source URL, `untrusted` true and no `next_offset`.

Every fetch outcome reports `body_total`, the decoded body bytes (zero when no body was retrieved). A ranged fetch (`offset` or `find` given) also reports `body_offset`, the source byte where `body` starts. `next_offset`, present only when source remains after fitting, is the first unconsumed source byte (`body_offset` plus the source bytes emitted); the synthetic untrusted marker consumes no source bytes. Pass it as `offset` for the next call; each call is one independent fetch, nothing is cached and no limit, timeout or retry changes.

Exception: a plain fetch (no `offset`, no `find`) returns exactly the body bytes it always did and adds only `body_total` and, when truncated, `next_offset`; it never reports `body_offset`. Search output is unchanged.
