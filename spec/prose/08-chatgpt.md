# 08 Subscription provider connections

ChatGPT and SuperGrok are supported providers. ChatGPT remains the default when a role omits `provider`. Kogen signs in with its own login flow, stores and refreshes its own credentials, streams responses with tool calls and usage, and reports provider problems precisely. It never borrows another tool's credentials, never falls back to a paid API key and never switches accounts. The route is OpenAI's official "Sign in with ChatGPT" plan usage for open-source apps, with dynamic client registration (developers.openai.com/siwc): authorization at `https://auth.openai.com/api/accounts/authorize`, tokens at `https://auth.openai.com/api/accounts/oauth/token`, inference at `https://api.openai.com/v1/responses`.

**GPT-1 — Own login only.** Kogen uses only credentials from its own `kogen provider login chatgpt`. It never reads Codex, ChatGPT desktop, browser or Claude credential stores, and accepts no token from the environment or arguments.

**GPT-2 — Login.** `kogen provider login chatgpt` runs the authorization-code flow with PKCE (S256), a fresh `state` and `nonce`, the scope `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` and the resource `https://api.openai.com/v1`. The first login registers Kogen dynamically (`client_id=dynamic_agent_client`, `agent_name_hint=Kogen`, a stable per-machine `ext_agent_host_id`) and keeps the issued `oaiapp_…` client ID for later logins and refreshes. Kogen prints `Continue with ChatGPT` and the authorization URL, opens the browser (not when `KOGEN_NO_BROWSER=1`), and waits up to 300 seconds for the redirect on `http://127.0.0.1:1455/auth/callback`, owned by the `kogen` process, or for that redirect URL pasted on stdin (for machines whose browser is elsewhere). A redirect with the wrong `state` is ignored. If the granted scope lacks `chatgpt.tokens.use.direct`, the login fails with `provider/login_failed: ChatGPT plan usage was not granted; sign in again and allow it` and nothing is kept. Success prints `chatgpt signed in[ (<email>)]` (exit 0) and replaces any earlier login; `access_denied` and other failures print `provider/login_failed: <detail>` (exit 4).

**GPT-3 — Storage.** Credentials (issued client ID, tokens, granted scope) live in `~/.kogen/credentials/chatgpt.json` (mode 0600, directory 0700), written atomically; the `ext_agent_host_id` lives in `~/.kogen/host-id`. The user signs in once per machine: every later command reuses these credentials, refreshes them (GPT-6) and saves each rotated refresh token, and a new login is needed only when a refresh fails for good. Kogen holds an exclusive lock on the credentials while it reads, refreshes and saves them: the lock file `~/.kogen/credentials/chatgpt.lock` is created exclusively (`O_EXCL`) and holds the pid; a process that finds it held waits, and a lock whose process is gone is removed. Under the lock Kogen re-reads `chatgpt.json` and uses a newer token if another process already refreshed.

**GPT-4 — Status.** The offline list prints the unchanged ChatGPT line followed by the SuperGrok line described below. `kogen provider list` prints `chatgpt: signed in[ (<email>)]` only when `~/.kogen/credentials/chatgpt.json` contains the issued `client_id`, `refresh_token`, `access_token` and `expires_at`. A missing credentials file prints `chatgpt: not signed in`; a saved file missing any required value prints `chatgpt: saved login cannot be used; run kogen provider login chatgpt` (exit 0). It makes no request.

**GPT-5 — Login required.** For provider-aware roles, check only the providers used: Shape plus enabled workers, Refine Shape, Build/resume Build and Review. Init remains ChatGPT. `init` (on a repository with commits), shaping and Builds refuse before any request when no credentials file exists: `provider/login: not signed in; run kogen provider login chatgpt`. A saved credentials file missing any required value in GPT-4 is refused as `provider/login: saved login cannot be used; run kogen provider login chatgpt`. Both exit 4.

**GPT-6 — Refresh.** Kogen refreshes the access token (one hour) before it expires and once after a 401, with the issued client ID and without `scope`, saving the rotated refresh token before using the new access token (all of it under the GPT-3 lock). If the Responses API returns 401 and refresh fails, or the authorization server rejects the saved refresh token with `invalid_grant`, Kogen prints `provider/login: the ChatGPT sign-in was rejected; run kogen provider login chatgpt` (exit 4). Other failed proactive refreshes print `provider/login: the ChatGPT sign-in expired and could not be refreshed; run kogen provider login chatgpt` (exit 4).

**GPT-7 — Streaming.** Every request is a `POST /v1/responses` with `store: false` and `stream: true`, the configured model and effort, the conversation and the tool definitions; Kogen assembles text, tool calls, the end of the response and usage. A stream that ends without its completion event is a transient failure; `[DONE]` alone is not success. Kogen returns promptly on a validated `response.completed` frame and cancels the unneeded HTTP request, without waiting for stream closure. The completion requires a response object, no recorded failure, and complete ordered output items with contiguous nonnegative indexes and no unfinished added item. Current `response.output_item.done` frames carry `output_index` and `item`; completion may contain only `response: {usage: ...}`. Omitted final output and `response.output: []` are metadata only: both retain streamed done items and the pending set. Empty metadata never establishes authority or clears unfinished items. Nonempty final `response.output` replaces streamed items and clears pending only under the existing terminal index coverage and validation rules; it may replace unfinished or invalid streamed items when those rules permit. Message content is validated; function calls require nonempty string call_id/name and string arguments decoding to a JSON object. Partial deltas and malformed output never authorize tools; caller tool authorization and validation remain in force. Observed failure, incomplete and error frames cannot become successful completion. Each request carries the whole conversation: `previous_response_id` is not supported on this route. Correctness does not rely on prompt caching. Supported documented GPT-5.6+ models request implicit 30m reuse, with explicit input_text policy/contract boundaries in their original authority roles; no prewarming, filler or conversation-loading fields. Full valid encrypted reasoning, assistant phase and tool-call fields replay in order, including frozen ordered typed view_image outputs. Text caps and unsupported-cache fallback must not stringify, clip or otherwise change image content. Comparison IDs remain scoped to independent conversations and safe checkpoints; reviewer histories are independent. A definite nonexecuting cache-parameter 400 permits one compatibility retry within the same absolute deadline. Recognized refusals are cache-named `unknown_parameter`, `unsupported_parameter` and `subscription_sharing_unsupported_capability`, or `invalid_parameter` with message exactly `prompt_cache_options is not supported on this model` and absent/null `param` or `param: "prompt_cache_options"`. A conflicting param, invalid TTL/mode, or cache field alone does not qualify. Only `prompt_cache_options` and content-block `prompt_cache_breakpoint` markers are removed; model, effort, authority roles, ordered full replay, tools and transport settings remain unchanged. Unsupported capability stays within that independent conversation and compatible checkpoint/resume, never reviewer state or replay authority. The refused attempt remains separate with unknown usage and no invented response ID, effective settings or applied TTL; actual request IDs and counts are retained. Uncertain execution and unrelated failures never trigger cache stripping. Earlier/unrecognized models omit controls and report unsupported/unknown. Diagnostics are optional, bounded classified evidence, never output validity or cache authority.

**GPT-8 — Errors and retries.** One logical `respond/5` call has a fixed 1,800,000 ms absolute monotonic budget established on entry before credentials, refresh and request work. Credential lock waits, refresh after 401, unreadable-response retry and 2 s/8 s backoff share that budget. Bytes, heartbeats and retries cannot renew it; expiry is checked even with a busy mailbox, and no attempt starts after expiry. HTTP waits and pauses use at most the remaining budget, preserving the 30 s connect ceiling and TLS verification. Expiry cancels outstanding Responses or refresh HTTP work and raises `provider/unavailable: ChatGPT response wait exceeded 30 minutes` (exit 4), without retry, invented provider code or fabricated usage. Known completed usage and unknown failed usage remain intact. Explicit Bridge cancellation remains prompt with signal exits 130/143/129, and only owned locks are released on every exit. A later call has its own budget; single-attempt mode retains its semantics.

| Situation | Behavior | When it stops |
| --- | --- | --- |
| network error, 5xx, 429 that is not a usage limit, cut stream | retry the whole request, 3 attempts in total, waiting 2 s then 8 s; partial output is discarded | `provider/unavailable: ChatGPT did not answer after 3 attempts: <detail>` |
| usage limit (`subscription_sharing_usage_limit_exceeded`) | no retry | `provider/usage_limit: ChatGPT usage limit reached[; it resets at <time>]` |
| 401 | one refresh, one retry (GPT-6) | `provider/login: …` |
| model not available to the account | no retry | `provider/model_unavailable: <model> is not available to this ChatGPT account` |
| context too long | no retry | LOOP-9 in a Build; `shape/provider_failed` in shaping |
| other 4xx | no retry | `provider/refused: ChatGPT refused the request: <status> <detail>` |
| unreadable response | one retry | `provider/invalid_response: ChatGPT sent a response Kogen cannot read: <detail>` |

Provider failures retain an allowlisted diagnostic map `provider_failure`: string `code` and error `type`, the enclosing SSE `event_kind` when supplied, and numeric `http_status` when known. Unknown codes remain diagnostic data and follow the same existing fallback classification; retaining them never adds a retry or changes the 2 s/8 s backoff, attempt count or exit. A final exhausted transient retains its last failure fields. Missing or nonstring fields are omitted safely, rather than copying malformed payloads. The existing error rendering adds a `provider failure: <JSON>` line; Build results, existing outcome log events and refinement failure results retain the same map, including when Build context exhaustion wraps the provider error. A flat SSE `error` frame's `type` names its event kind, not an error subtype; `response.incomplete`'s synthetic internal marker is not a provider code. No raw stream/event body, prompt, request payload, authentication field or credential is added to these diagnostics.

Terminal-invalid output retains the detail prefix `the completed response has invalid or unfinished output` and appends `; validation=<JSON>`. This is local structural evidence, not a provider code or a diagnosis of a live failure. The object has exactly `reasons` and `facts`, at most 2048 UTF-8 bytes. Sorted deduplicated reasons name evaluated failures: `item_event_shape`, `terminal_envelope`, `response_status`, `response_error`, `usage_shape`, `terminal_output_shape`, `terminal_index_coverage`, `empty_output`, `noncontiguous_indexes`, `pending_items`, `item_status`, `item_shape`. Sticky envelope/event/coverage failures survive terminal replacement; item/status/pending/index predicates describe effective output only.

Facts contain exactly `event_kind` (`response.completed`), `done`, `terminal_response_present`, `terminal_output_present`, `terminal_output_replaced`, `item_count`, `pending_count`, `observed_index_count`, `counts_capped`, `indexes_contiguous`, `item_types`, `item_statuses`, and `arguments_object`. Counts saturate at 1024 and `counts_capped` indicates overflow; observed indexes are the union of streamed done/pending indexes before replacement (or at completion without replacement). For rejected empty final output, terminal response/output are present, replacement is false, and effective facts describe the retained items and pending set without empty-list coverage evaluation. Effective-item aggregates are sorted and deduplicated: types are function_call/message/reasoning/other/unknown; statuses completed/in_progress/incomplete/failed/other/unknown; function-call argument object decoding is yes/no/unknown. Unknown means absent/null/nonstring; other maps unknown strings without copying them. No raw content, arguments, tool names, identifiers, hashes, traces or arbitrary provider strings enter this evidence. Existing per-transport failed records carry the detail in order, including before a successful retry; rejected usage stays unknown even if usage fields were valid. Other failure precedence, single-attempt prefixes, retry policy and authority are unchanged.

Documentation-shaped local streaming/function-call fixtures (official Responses streaming events and function-calling streaming documentation fetched 21 October) are compatibility tests, not live captures or evidence of an upstream cause. No mismatch with those examples has been established.

All exit 4, except context exhaustion in a Build, which is LOOP-9 (exit 1). A retry never repeats a tool call: tools run only after a complete response. A provider failure ends a Build without a commit, edits left.

**GPT-9 — Usage.** Kogen records each transport attempt append-only with real response/request IDs, nullable effective configuration, bounded cache diagnostics, local-byte segment fingerprints, validated nullable token/write/lifetime categories and measured wall time. Failed or unconfirmed streams have unknown usage. Existing compatible summaries remain, linked by operation ID and never counted beside transport rows. The Build result and shaping output print compatible totals. The local report in [usage.md](../../docs/usage.md) counts retained attempts once, excludes inconsistent evidence from arithmetic and never converts to dollars or weekly quota.

**GPT-10 — Secrets.** Tokens and authorization codes never appear on stdout or stderr, in run records, error messages, commands' environment or any argv.

**GPT-11 — Test seams.** `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` replace the provider and authorization base URLs for tests and accept only `http://127.0.0.1:<port>` or `http://localhost:<port>`; any other value is `environment/invalid_test_seam: <NAME> must be http://127.0.0.1:<port> or http://localhost:<port>` (exit 3).

Scenarios: `features/08-chatgpt.feature`.

## SuperGrok subscription route

The same status, secret, transport, usage and loopback-seam requirements apply to
SuperGrok, with these provider-specific behaviors. The installed local-fake
journeys are also maintained in the SuperGrok Intent's acceptance feature; they
exercise login/refusals, Shape/Refine/Build/fresh Review, limits and legacy resume.

### Selection and identity

Every model role and Shape worker accepts optional `provider: chatgpt|supergrok`.
Omission preserves exact legacy maps, request bytes, cache behavior and version-3
checkpoint comparisons; explicit ChatGPT adds only the selected provider key.
SuperGrok accepts exactly `grok-4.7`, effort `low|medium|high|xhigh`. Invalid provider
values report `models.<role>.provider must be chatgpt or supergrok`; unsupported
selections report `models.<role>: supergrok supports model grok-4.7 with effort low,
medium, high or xhigh` (workers use `shape_workers.<role>`). Both use existing
line-numbered `environment/project_config_invalid`, exit 3. A provider edit changes
approval and refuses resume; no migration of existing saved configuration occurs.

### Device login and storage

`kogen provider login supergrok` POSTs `https://auth.x.ai/oauth2/device/code` with
exact form fields `client_id=b1a00492-073a-47ea-816f-4c329264a828`,
`scope=openid profile email offline_access grok-cli:access api:access`,
`referrer=kogen`, and headers `accept: application/json`, `user-agent: kogen/<id>`
(the second token of `Kogen.version()`). Non-200 stops after one request with
`provider/login_failed: the SuperGrok device authorization request failed
(<status>[ <error>])`. No alternate identity is attempted.

Require nonempty device/user code and verification URI, positive integer
`expires_in`, else `the SuperGrok device authorization response is incomplete`.
Both verification URI and any complete URI must be absolute HTTPS with host,
else `the SuperGrok verification address is not HTTPS`, before any polling.
Stdout prints exactly `Continue with SuperGrok`, complete URI (else base URI),
`Code: <user_code>`. No listener/browser starts; device codes are never printed.

Token polls POST `https://auth.x.ai/oauth2/token` with only
`grant_type=urn:ietf:params:oauth:grant-type:device_code`, device code and client ID.
Wait at least the server interval before every poll, including first (absent = 5s,
minimum 1s); pending continues and slow_down permanently adds 5s. No poll starts at
or after the returned lifetime measured from the device answer. Denial prints
`the SuperGrok sign-in was denied`; expired_token or deadline prints
`the SuperGrok sign-in code expired`; other errors print
`the SuperGrok token request failed (<status>[ <error>])`. All these messages use
`provider/login_failed`, exit 4; cancellation instead retains signal exits and
stops waiting/HTTP promptly. Failed login preserves earlier credential bytes.

Grant access/refresh tokens must be nonempty, else `the SuperGrok sign-in returned
no usable tokens`. Granted scope must contain api:access; absent scope means the
requested scope. Missing access prints `SuperGrok API access was not granted; sign
in again and allow it`. Successful atomic locked storage has exactly client_id,
referrer=kogen, access_token, refresh_token, expires_at (now + expires_in, else
3600), scope, and optional string email from id_token payload. Never persist
id_token, user or device code. Credentials are 0600 at
`~/.kogen/credentials/supergrok.json`, both parent directories 0700 even at umask
022, using `supergrok.lock` with the same ownership/stale rules as ChatGPT.
Success prints `supergrok signed in[ (<email>)]`, exit 0.

Offline list prints `supergrok: not signed in`, `supergrok: signed in[ (<email>)]`,
or `supergrok: saved login cannot be used; run kogen provider login supergrok`.
Usability requires nonempty string client_id/access_token/refresh_token, integer
expires_at and referrer exactly kogen. Required-role checks print
`provider/login: not signed in; run kogen provider login supergrok` or
`provider/login: saved login cannot be used; run kogen provider login supergrok`,
exit 4, before any request.

### Responses, refresh, refusal and retained evidence

POST `https://api.x.ai/v1/responses` with application headers only Bearer
authorization, accept text/event-stream, content-type application/json and Kogen
user-agent. Transport framing headers remain ordinary HTTP. No harness,
conversation, cookie or API-key header or previous_response_id. The existing
request body retains model, reasoning.effort, encrypted reasoning include,
complete ordered input, stream true, store false, plain instructions and tools
with auto choice when present. SuperGrok never sends cache options/breakpoints or
a developer policy message; cache status is unknown, boundaries empty. ChatGPT
cache retry and subscription_sharing handling are ChatGPT-only.

Refresh when expires_at - 60 <= now and once after 401, locked with re-read,
POSTing only grant_type=refresh_token, refresh_token and client_id. Keep old
refresh token if rotation omitted, expiry from expires_in else 3600. invalid_grant,
any failure after 401, and a second 401 print `provider/login: the SuperGrok
sign-in was rejected; run kogen provider login supergrok`; other proactive failure
prints `provider/login: the SuperGrok sign-in expired and could not be refreshed;
run kogen provider login supergrok`.

402 stops with `provider/refused: SuperGrok reported a billing or credit limit
(402[ <detail>]); Kogen uses only the subscription sign-in and never falls back to
paid API usage`; 403 stops with `provider/refused: SuperGrok denied API access for
this sign-in (403[ <detail>]); Kogen never falls back to an API key or another
provider`. Neither retries. Network/429/5xx/cut streams retain 3 attempts with
2s/8s waits, then `provider/unavailable: SuperGrok did not answer after 3 attempts:
<detail>`. model_not_found prints `provider/model_unavailable: grok-4.7 is not
available to this SuperGrok account`; context_length_exceeded retains context
handling. Other 4xx print `provider/refused: SuperGrok refused the request:
<status> <detail>`; unreadable output prints `provider/invalid_response: SuperGrok
sent a response Kogen cannot read: <detail>`. Budget expiry prints
`provider/unavailable: SuperGrok response wait exceeded 30 minutes`. All exit 4
except existing Build context handling. No pool-exhaustion code is invented.

Every new attempt carries the routed provider; usage JSON rows expose it and
older missing fields stay null, never inferred. Absent categories stay null.
There is no cost/quota/savings claim. Full encrypted reasoning, assistant phase,
tool pairs, frozen typed images, full rendered 524288-byte inclusive ceiling and
131072-token reserve, independent Review, pinned source delivery and version-3
checkpoints are unchanged. Images are never textual substitutions. Local fakes
establish plumbing, not account acceptance, pixel interpretation or pool charging.
Kogen never reads other harness stores, ~/.grok, cookies or XAI_API_KEY, nor calls
grok.com or cli-chat-proxy.grok.com. Both URL overrides keep the existing loopback
rule. See the human-consent installed qualification handoff in
[configuration.md](../../docs/configuration.md#installed-qualification-handoff):
low tool-using Shape first, then changed installed high/medium/high roles before
Intent 2, with actual nullable request evidence and separately observed account
Usage/Extra Usage; unobserved facts remain UNKNOWN. No live probe is part of tests.
