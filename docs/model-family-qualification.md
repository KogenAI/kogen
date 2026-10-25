# Qualified model-family profiles

This completes the remaining official-family-settings outcome of KOGEN-057. Open
selection was already delivered: arbitrary nonempty model and effort strings remain
configurable and are sent unchanged. Recommendations, saved logins, documentation,
and synthetic answers are not official qualification. No wildcard, prefix or version
inheritance is used. New exact IDs need their own reviewed evidence.

`kogen provider list` preserves the local login lines in order and appends official
compatibility. `kogen provider list --json` returns schema version 1 and the two exact
profiles in the order below, including settings, nullable documented limits,
qualifications and independently scoped evidence. Both are offline: neither refreshes
credentials, checks an account nor contacts a provider. They expose no credentials.

## Exact supported scope

| Profile | Exact provider/model | Native role/effort | Evidence IDs |
| --- | --- | --- | --- |
| `chatgpt-sol-6-1` | `chatgpt/gpt-6.1-sol` | Shape/high | `go-live-2026-10-24` |
| `chatgpt-sol-6-1` | `chatgpt/gpt-6.1-sol` | Build/medium | `go-live-2026-10-24` |
| `chatgpt-sol-6-1` | `chatgpt/gpt-6.1-sol` | Review/high | `native-go-sol-review-2026-10-24` |
| `anthropic-sonnet-5-5` | `anthropic/claude-sonnet-5-5` | Review/medium | `go-live-2026-10-24` |

Only normal vendor routes with text/tool input qualify. Refine uses Shape's
selection; optional workers do not inherit Shape qualification. Sol Review/medium,
other roles/efforts, alternate versions, Kimi, SuperGrok, all compatible hosts
(including one advertising a known model ID), custom endpoints and either
`KOGEN_PROVIDER_URL` or `KOGEN_AUTH_URL` override are **experimental**. They may fail
and are not blocked. The configured native roles are not changed by this catalog.
Actual Ollama/LM Studio/vLLM servers are not qualified by local fixtures.

Each new transport attempt records `compatibility` with `status`, nullable `profile`,
actual native `role`, `provider`, configured `model` and unchanged `effort`. A known
profile remains identified even for an unqualified effort/role. Unknown pairs have
null profile. Response-reported model names do not grant support. Classification
is not HTTP success, cache-hit evidence, access or an availability guarantee. Old
retained records without it remain unknown and are not rewritten or upgraded;
the usage reader preserves recorded classification without reconstructing history.
Provider refusals retain existing stop/no-fallback behavior and contextual diagnostics
name the editable selector, e.g. `.kogen/project.yaml models.review.model` and
`models.review.effort`, not a fabricated numeric line. Review SuperGrok
`no-such-model` with HTTP 400 `model not found` sends once and stops.

## Operational policy and documented bounds

The exact resolver is shared by classification, rendering, preflight limits and
presentation. Known settings still apply to experimental roles/efforts on that
exact family; unknown IDs retain the provider/wire fallback with unknown family
limits, not guessed ones. No parameter is sent solely because documentation names it.

| Profile | Route | Documented context / max input / max output (tokens) |
| --- | --- | --- |
| Sol 6.1 | `https://api.openai.com/v1/responses` | 1050000 / 922000 / 128000 |
| Sonnet 5.5 | `https://api.anthropic.com/v1/messages` | 1000000 / unknown (JSON null) / 128000 |

Both profiles document efforts `low`, `medium`, `high`, `xhigh`, `max`; this is not
qualification of all those selections. Sol uses streamed Responses,
`reasoning.effort`, encrypted reasoning inclusion and ordered item replay, native
tool schemas with auto choice, `store: false` and the conversation's
`prompt_cache_key`. The current contract additionally sends underscore `session_id`
and `conversation_id` headers, each equal to the existing bounded conversation
identity, even when exact-key compatibility suppresses the body key. There is no
`prompt_cache_options`, private-backend `session-id` header or new maximum-output parameter. Output and reasoning share the documented output
allowance; the 131072 reserve is conservative accounting, not extra wire allowance.
ChatGPT typed-image plumbing remains experimental, not qualified visual interpretation.

Sonnet uses streamed Messages, API version `2026-10-21`, adaptive thinking and
`output_config.effort`, `max_tokens: 128000`, auto (not forced) tools and
`input_schema` conversion (no invented strict-schema guarantee). Exact signed
thinking and assistant messages replay once. Ephemeral cache breakpoints remain on
the last tool, system block and newest eligible message. No manual thinking budget,
forced tools, mid-conversation model switch, changed replay prefix or enabled image
input is introduced. Anthropic and chat-wire typed images still refuse before
inference: use external image preparation and a pixel-review handoff. API vision
availability does not qualify native Kogen pixel review.

The complete serialized next request still has an inclusive **524288-byte** guard
and **131072-token** output/reasoning reserve in every caller and provider preflight.
For known bounds, usable input is the minimum of the global byte cap, any known
maximum input and context minus reserve, conservatively treating bytes as tokens.
Both shipped profiles remain below those documented capacities after reserve.
Equality fits; adjacent overflow stops before inference. No clipping, selective
loss of authority/history, dropped tool pairs, new user budget knobs or speculative
tokenizer is allowed. Unknown families are not claimed to fit: provider context
errors below the proxy remain honest failures. Original source/approval custody,
replay, cache identities and independent review remain intact.

Generic compatible hosts get no vendor cache controls or foreign credentials.
Usage stays recorded even when models/prices are unknown. No new prices or
subscription-cost estimates are inferred from vendor API pricing; synthetic tests
prove transport/policy only, not cache savings or universal account access.

## Changed-header qualification boundary

The historical receipts below used the prior no-affinity-header policy. Their
unchanged-wire comparisons describe those historical candidates, not this changed
request. The catalog's text/tool evidence is not installed qualification for the
new headers, nor proof of cache benefit. Local recording-server acceptance proves
deterministic plumbing only. No historical approval or green check is imported.

After Build, private installed-candidate qualification still requires the existing
procedure and mandatory private authentication/consent handoff before any unadmitted
live action. Keep the admitted route/model/auth/limits unchanged and bind the exact
candidate and observed headers, input, replay, correctness and usage to retained
evidence. A failed, null or unsupported attempt remains visible and is not installed
qualification. External CACHE-BEST C3/KOGEN-060 observations (research draft author
kogen-research-owner, measured against 687f1407) selected the two-header mechanism,
not a savings threshold or all-model claim; reuse requires independently established
relevant wire/input equivalence. No paid comparison or new benchmark framework is
introduced, and independent Studio operations are untouched.

## Historical qualification custody

### `go-live-2026-10-24`

Recorded 2026-10-24, the installed Go journey used source candidate tree
`7e708f1c81a8d9d68956e422f2935b3959fc7639`, archive SHA-256
`eaa60cc4383f25180542bf97f572b653a773dbc46538a48f816e519c0b76beee`, and landed
fixture commit `bd800096ab51c34a8a4ce4fca7696122f0152b5b`. It demonstrated only
Sol Shape/high, Sol Build/medium and independent Sonnet Review/medium,
text/tool/stream/replay/cache-control behavior. Usage coverage includes uncertainty:
not all-known usage, savings, every schema, limit stress, image approval or today's
account availability.

Shape inspected the selected receipt at
`/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-repairs/go-core-migration-20261024/root-takeover-20261024/live-go-qualification/receipt.json`.
Its read-only comparison found no differences anywhere in `cli/provider` against
installed baseline `f38e488778c198e57d90ca1fc17a13c664168919`. Reuse is based on
this profile's unchanged wire/input policy described above, not on model naming.
The separate cache delivery is not Go proof for other models. Historical Kimi and
SuperGrok observations do not qualify this catalog.

### `native-go-sol-review-2026-10-24`

This separate citation supports **only Sol Review/high** text/tool behavior, not
another effort or role. Native Refine inspected each retained run's `log.jsonl`,
`review-1.json` and `result.json`, external Build launches, retained installed
binaries/version files and delivery receipts. Historical verdicts are evidence,
not approval/checkpoint imports or waived gates.

| Native run | Executing installed Go version and binary SHA-256 | Start head → landed commit | Review tree / historical verdict | `review-1.json` SHA-256 |
| --- | --- | --- | --- | --- |
| `553c44bd` | `kogen d0bc4af0 (2026-10-24)`; `fe374affa7b4b94ec67299dfe3639dd21b9e0e2fab194fe5f713b08480f5f536` | `d0bc4af0804876eea2724b412451c1cdb7028248` → `687f140700426b3b4ad3e3eae7f1d854762dad31` | `0341c848eaefb29fecd932ecb8f1f30d4537b12f` / `approve` | `9e559a179585b1604e5c429357a5b03fcfb9f33fb2abacc83fc0469ce11f9fe6` |
| `b515525a` | `kogen 687f1407 (2026-10-24)`; `c0e21b0f7ef17cea2cee1eb5cf9a99bb85ae6bd6fc1eff4fa74a12f893a1a092` | `687f140700426b3b4ad3e3eae7f1d854762dad31` → `f38e488778c198e57d90ca1fc17a13c664168919` | `3f6f701def347f08f36519db434132ef1304aea3` / `approve` | `2464a2a68b05e63508745a5a65888fd0554f67347d7c92eaa163492b13a15c1c` |

Run logs show Build `chatgpt/gpt-6.1-sol/medium` with 18 and 13 completed attempts,
and fresh independent Review `chatgpt/gpt-6.1-sol/high` with 23 and 14 completed
attempts, respectively. Builder/reviewer conversation identities are distinct;
Review configured and effective model/effort agree. The launch records under
`/Users/almirsarajcic/Areas/Kogen/studio-work/post-go-roadmap-20261024/{protected-harness-readiness-build,kogen-check-time-build}/launch.json`
select the Go and readiness delivery prefixes respectively. Retained binary hashes
equal launch hashes: these are executing runtimes, not later landed versions.
Readiness and check-time receipts establish subsequent lineage, not more model
qualification. The final 687 and f38 installed binary hashes are identical.

Native read-only `git diff --exit-code` comparisons of all `cli/provider` for
d0bc4af → 687f1407 and 687f1407 → f38e4887 each exited 0 with empty output.
All three directory trees are `ea5efa099be455516ed87e6ebc1840874f408b72`.
Despite runtime-binary changes in the first delivery, provider policy was unchanged:
Responses route, streaming/tools/replay/auth and `prompt_cache_key`. This does not
qualify images, cache savings or current account access.

## Documentation versus demonstration

Shape's retained native documentation records fetched these authoritative sources:

- <https://developers.openai.com/api/docs/models/gpt-6.1-sol.md>
- <https://developers.openai.com/api/docs/guides/reasoning.md>
- <https://platform.claude.com/docs/en/models/sonnet-5-5/overview.md>
- <https://platform.claude.com/docs/en/build-with-claude/effort.md>
- <https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5.md>

Some retained bodies were bounded/truncated. Unsupported discovery searches were
not successful fetches. These sources establish documented limits and relevant
effort/tool/thinking differences, not subscription access or Kogen qualification.
Sonnet documents adaptive/between-tools thinking rather than older disabled/manual
budgets, rejects forced tools and binds thinking to model/conversation; the existing
demonstrated adaptive/auto/append-only policy is retained.

Ordinary final verification and fresh independent final-tree review must establish
the current request/route/auth contract. Historical reuse requires unchanged qualified
wire/input policy; the changed ChatGPT headers require new installed-candidate
qualification as described above. Material changes invalidate historical reuse,
not authorize paid work. Signed/pushed/private
qualification/adoption are separate delivery operations: this documentation,
synthetic acceptance and Intent approval do not claim them performed. No paid probe,
authentication flow, credential copying, fallback, endpoint/billing/cap change,
public deployment, Studio change or prior approval/check import is included.
