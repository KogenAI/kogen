# `Kh.Session` runtime API

This directory is the standalone Mix project for the production custom runtime.
It contains one agent loop for product and non-product callers, ChatGPT
Responses streaming, the real read/write/edit/bash tools, durable checkpoints,
and a strict session-local scripted provider for offline tests. Inputs to the
model are text only. Tool calls are still executed by the real runtime tools.

## Build and focused checks

Start in `runtime/kh`. With Elixir and Mix installed, run:

```sh
mix compile
mix test
```

The tests cover fragmented SSE parsing and error classification, rendered
maximum effort, real tool execution under scripted model replies, strict
script mismatch handling, fresh-process checkpoint restore with appended
input, usage evidence, and cancellation of a registered Bash process. They do
not exercise live authentication or make network requests. The broader native
Kogen gate and upstream benchmark suites are outside this bounded import.

## Open, run and continue a session

`Kh.Session.open/1` returns `{:ok, pid}` or `{:error, reason}`. A fresh
session needs a provider (`:chatgpt` or `:scripted`), a model id, a working
directory, a nonempty caller-supplied system prompt, and a checkpoint path.
`run/2` returns `{:ok, run_ref}`. `await/3` returns
`{:ok, result}` containing a summary, JSON-safe events and evidence.

```elixir
{:ok, session} = Kh.Session.open(%{
  provider: :scripted,
  model: "offline-test-model",
  cwd: "/tmp/work",
  system_prompt: "You are a coding agent.",
  checkpoint_path: "/tmp/work/.kh/session.json",
  scripted_replies: [
    %{
      "expect" => %{"last_user_text" => "read the file"},
      "reply" => %{"tool_calls" => [
        %{"name" => "read", "args" => %{"path" => "notes.txt"}}
      ]}
    },
    %{
      "expect" => %{"last_tool_name" => "read", "last_tool_is_error" => false},
      "reply" => %{"text" => "The file says hello."}
    }
  ]
})

{:ok, run_ref} = Kh.Session.run(session, "read the file")
{:ok, result} = Kh.Session.await(session, run_ref, :infinity)
```

After a successful complete run, append a Shaper answer or Developer rework
prompt with `Kh.Session.append_input(session, text)`. `resume/1` continues the
exact checkpoint without adding a user turn. To continue in a new process,
open with the same immutable run configuration and
`restore_from: result["evidence"]["checkpoint_path"]`; use the same
`checkpoint_path` to advance that transcript. A scripted restore must also
provide a fresh `scripted_replies` list. No scripted request queue or reply is
stored in the checkpoint. The restored process keeps the checkpoint's
session id, rejects mismatched model, provider, system prompt, effort, tools,
turn allowance, cwd or ChatGPT account, and accepts newly appended text only
after a prior successful completion.

```elixir
{:ok, restored} = Kh.Session.open(%{
  provider: :scripted,
  model: "offline-test-model",
  cwd: "/tmp/work",
  system_prompt: "You are a coding agent.",
  checkpoint_path: "/tmp/work/.kh/session.json",
  restore_from: "/tmp/work/.kh/session.json",
  scripted_replies: [
    %{
      "expect" => %{"last_user_text" => "please revise the summary"},
      "reply" => %{"text" => "Revised summary."}
    }
  ]
})

{:ok, next_ref} = Kh.Session.append_input(restored, "please revise the summary")
{:ok, next_result} = Kh.Session.await(restored, next_ref, :infinity)
```

`cancel/1` kills only tools registered to that session and its runtime worker.
Cancellation evidence states whether a fresh checkpoint was saved. The
retained B011 Bash monitor also cleans up descendants if the owning VM dies.
The existing parent process remains responsible for custody around an
external child runtime.

## Provider and authentication boundary

`:scripted` runs entirely in memory and never calls the network provider.
Every reply step has an `"expect"` map and a `"reply"` map. Expectation keys
are `model`, `effort_sent`, `session_id`, `tool_names`, `message_count`,
`last_user_text`, `last_message_role`, `last_tool_name` and
`last_tool_is_error`. A mismatch, missing step or exhausted queue is fatal;
there is no live fallback. Replies can provide `"text"`, `"tool_calls"`,
`"reasoning"`, `"usage"`, or a typed `"error"`. An explicit error reply can
simulate `fatal`, `transient`, `rate_limit`, `auth` or `timeout` outcomes.

`:chatgpt` sends streamed Responses requests to the ChatGPT subscription
backend. The caller must pass `access_token` and `account_id` from the selected
Codex access-only login state. `Kh.Session` does not search credential files,
refresh credentials or copy auth material. It rejects a parseable JWT expiry
less than 60 seconds away; it does not validate opaque tokens or prove that an
access token works until a request is made. The token stays in session-process
memory and request headers and is not written to the checkpoint. Only the
SHA-256 account id hash is persisted to bind a ChatGPT checkpoint.

The runtime supports ChatGPT Responses only. The direct JSON body includes the
session prompt, text transcript, selected tools and requested effort. For
`gpt-6-luna`, `gpt-6-astra` and `gpt-6.1-sol`, `max` is sent as `max`; other
models retain their previous effort map and reject unsupported settings during
session admission. No effort ladder, model substitution or default is added.

## Events and evidence

Each event is a JSON-safe map with `t` (milliseconds from this process's open),
`ts` (UTC ISO timestamp), `type`, `session_id`, `run_id` and `data`. The
optional `event_sink` receives these maps as they arrive. Important event types
include `run_start`, `turn_start`, `turn_end`, `tool_start`, `tool_end`,
`retry`, `failed_attempt_usage`, `recovery_uncertain`, `warn` and `run_end`.

Use `result["evidence"]` or `Kh.Session.evidence/1` as the evidence contract.
Usage fields and returned events are scoped to the latest `run_id`; the
checkpoint and stable `session_id` cover the full conversation.
`usage` is non-null only when every completed turn reported usage and the run
had no retries. `usage_state` is `reported`, `partial` or `unknown`.
`usage_observed` reports only successful turn usage actually received;
`failed_attempt_usage_observed` reports only failed-attempt usage that was
actually received. The human-facing summary also sets aggregate usage to null
when incomplete, so absent provider fields are never presented as zero usage.
Checkpoint evidence includes the absolute path, file SHA-256, phase, turn,
elapsed time, error and a `resumable` flag. Checkpoint files are atomically
written with mode `0600`; they contain the text transcript, tool continuation,
runtime/provider binding and elapsed accounting, but never auth tokens or
script queues.

## Low-level boundary and limitations

`Kh.Agent.run/1` is the synchronous internal loop. It returns a summary map.
`Kh.Agent.run_continue/3` takes the same runtime options, a decoded checkpoint,
and an optional appended input. `Kh.Session` supplies explicit system context,
provider selection, JSON events, isolated scripted replies, session-keyed
process custody, checkpoint validation and cancellation around that loop.
Product consumers should use `Kh.Session` so these boundaries stay shared.

This source import does not include the upstream CLI, OpenCode provider
platform, Claude-only backend modules or their exclusive test suites. The
session API is ready for the role adapter, but each Shaper, Developer, fresh
Reviewer, Auditor and Expert lifecycle still needs to wire open/run/resume/
append/cancel and preserve the returned evidence. The runtime tests are
focused checks, not qualification of those role adapters or a full native
product cutover.
