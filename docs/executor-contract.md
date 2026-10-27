# Kogen executor contract v2

Status: **frozen for implementation, 26 October 2026** (kogen/kogen-loop extraction). Contract id: `kogen.executor/v2` (v2 of 27 October 2026 adds the shape and review roles; v1 described Build claims only and is no longer accepted). Owner: the extraction orchestrator, until accepted at the integration boundary. Code: `cli/executor` (types, the conformance harness and scripts). Changes to this file and `cli/executor/executor.go` go together.

An **executor** produces a candidate for one Build role in the user's checkout. Kogen keeps everything that makes a delivery trustworthy:
- the approved Intent and protected baseline;
- the fixers, verification passes and stage gates;
- independent review;
- the single verified commit;
- checkpoints and recovery.

v2 executors may serve the **shape** (including Refine), **build** and **review** roles, each configured independently and each with its own capabilities, session and evidence. An omitted role or `executor: native` is Kogen's own native role; the native Build adapter does not claim the native Shape or Review paths. No role chooses another role's executor, shares a session with it or falls back to the native path when the selected executor fails.

| Executor | Where | What runs the model |
|---|---|---|
| `native` | `cli/build` (adapter) over kogen-loop's `loop` engine | Kogen's own loop: providers, tools and context via kogen-loop, checkpoints via Kogen hooks |
| `claude-code` | `cli/executor/claudecode` | the user's installed Claude Code CLI, headless, through the user's own subscription sign-in |

## 1. Invariants

- **E1 Claims only.** A round result is the executor's claim (`finish`, `no_call`, `blocker`) plus untrusted text. No executor field, model output, tool or caller flag can mean verified, approved, reviewed or committed. After every round Kogen runs its normal round end: fixers, then the stage gate or a whole-Intent pass, then independent review and the exact-tree commit. A red result goes back to the same executor session as feedback.
- **E2 Deterministic authority.** Approval, the protected baseline, checks, review and commit are decided by Kogen code over the actual tree, never by an executor. Builder-reported blockers keep the existing validation and BUILDER-REPORTED label.
- **E3 Three distinct protection layers.**
  - *Prevention* is executor-specific and best effort: native `write_file` refusal; a Claude Code PreToolUse hook denying Write/Edit/MultiEdit/NotebookEdit on protected paths.
  - *Detection* is Kogen-owned and executor-independent: `BaselineIntact` and `headIntact` after every native shell call and after every executor round.
  - *Final verification* is Kogen's exact-tree verification, review and commit.

  Prevention never substitutes for detection or verification. A worktree or permission mode is not process isolation.
- **E4 Honest capability.** Each executor declares its capabilities (§3). A missing capability is refused or reported as unsupported, never imitated. For example, Claude Code has no exact resume in v1, so `kogen intent resume` refuses its checkpoints with `candidate/resume_refused`.
- **E5 Native compatibility.** With no `executor` configured, or `executor: native`, behavior is unchanged:
  - the same model-facing bytes and wire bodies;
  - the same checkpoint bytes (the new executor identity is omitted for native);
  - the same events, stops and resume.

  Existing version 3 checkpoints resume as before.
- **E6 Credentials and billing.** Executors use only the user's own existing sign-in. The Claude Code adapter:
  - removes API-key, base-URL, cloud-provider and nested-session variables from the child environment;
  - never passes `--bare`;
  - never reads, copies, stores or proxies tokens;
  - refuses a run whose reported auth route is not the subscription sign-in (`executor/auth_refused`).

  No paid-route fallback exists. Personal local use doesn't imply any distribution entitlement.
- **E7 Process custody.** Every executor process and its children run in their own process group. Cancellation, interruption or deadline terminates the whole group (SIGTERM, then SIGKILL after a bounded wait) before the round returns.
- **E8 No prompt cloning.** Adapters give external harnesses the task and constraints only: Intent, acceptance, README, testing rules, commands, protected paths, file list and feedback. They don't copy Kogen's native builder prompt or prescribe the harness's internal workflow, tools or subagents.

## 2. Go API (`cli/executor`)

```go
const Contract = "kogen.executor/v2"

type Executor interface {
    Describe() Descriptor
    // Start validates availability, version and auth route (no model work) and returns a session.
    Start(ctx context.Context, t Task, emit Sink) (Session, error)
}

type Session interface {
    // Round runs one round. First: in.Brief is the task. Later: in.Feedback is Kogen's
    // deterministic verification/stage/review feedback for the same session.
    Round(ctx context.Context, in Input) (RoundResult, error)
    // Handle identifies the session for the run log and checkpoint.
    Handle() Handle
    Close() error
}
```

**Types** (see `executor.go` for exact fields):
- `Descriptor{Name, Contract, Version, Capabilities}`
- `Task{Role, Root, Brief{Stable, Dynamic}, Protected, Excluded, Model, Effort, Approval, StartTree, RunID, Deadline, MaxRounds, Home, Dir}`
- `Input{Feedback string}` (empty for the first round)
- `RoundResult{Ending, Claim, Blocker *BlockerClaim, Usage, Handle}`
- `Usage{Input, Cached, Output, Reasoning *int; State; Source; CostUSD *float64; Model string}`
- `Handle{Executor, Version, SessionID string; Resume string}`

Events go to `Sink` as run-log maps with an `event` key of the form `executor_*`.

## 3. Capabilities

`Descriptor.Capabilities` is the Build claim (as in v1). `Descriptor.RoleCapabilities` lists the capabilities of each served role separately (`For(role)`, `ValidateRole(role)`): a Build claim is never evidence for Shape or Review. Per role it reports `resume`, `continuation`, `usage`, `prevention`, `blocker`, `images`, `probe`, `workers`, `structured`, `max_rounds` and explicit `limitations`.

Claude Code (all three roles) supports same-session continuation only within a running role invocation, harness usage and its existing process custody. It does **not** support exact persistent resume, Kogen-custodied typed images, Kogen scratch `probe`, native working-window replay or Shape workers; a Claude Code shaper with enabled workers is refused before inference. Claude's own Bash, research, images and subagents are not relabelled as those Kogen capabilities, and research through them is harness-observed only, never a Kogen documentation record.

Shape and Review (`structured`: true) receive `Task.Schema` and request schema-constrained output (`--json-schema`). The submission is the **final successful result's `structured_output` object** (`RoundResult.Structured`), complete and unclipped; text, intermediate tool input or a missing/malformed object is `executor/protocol`, never completion. The Shape schema carries the existing `submit` payload and the Review schema the existing `submit_review` payload, revalidated by Kogen's semantic validators. Every role starts a fresh session (`--session-id`, never `--resume`, `--continue` or `--fork-session`); only that role's later feedback rounds `--resume` it. A prompt over the inclusive 16 MiB bound stops `candidate/context_budget_exceeded` before it is sent. Shape is read-only (the PreToolUse hook denies every write; Kogen detects checkout, index and HEAD changes independently); Review keeps the Build protected-path prevention and detection.

| field | native | claude-code (build; see the per-role paragraph above) |
|---|---|---|
| `roles` | `build` | `build` |
| `resume` | `exact` (Kogen checkpoint at every tool boundary) | `none` (resume refused) |
| `continuation` | same conversation across rounds | same Claude session across rounds (`--resume <session_id>` within one Build process) |
| `usage` | `provider` (exact provider-reported fields) | `harness` (Claude Code's reported usage; cost is Claude Code's API-equivalent estimate, **not a bill**) |
| `prevention` | `write_tool_refusal` | `pretool_hook_write_edit` (Write/Edit/MultiEdit/NotebookEdit; Bash is **not** prevented) |
| `detection` | Kogen: baseline after each shell call + after round | Kogen: baseline + HEAD after each round; optional PostToolUse Bash observation hook |
| `blocker` | `report_blocker` tool | not supported in v1 |
| `images` | `view_image` | harness-native, not Kogen-custodied |
| `cancel` | context + tool process groups | process group of the `claude` process |
| `max_rounds` | unlimited (unchanged) | default 6, configurable; exceeding it stops with `candidate/executor_round_limit`, candidate preserved |

**Routing status.** All three roles are routed. Review uses the `Reviewer` seam: a fresh session, complete source delivery, the native verdict rules and exact-tree evaluation, no exact resume (`candidate/resume_refused`). Shape and Refine run one read-only session per invocation whose structured result is the existing `submit` / `submit_refinement` payload; Kogen compares the checkout, raw index and HEAD around every round.

## 4. Errors

`*sys.Error` stops:
- `executor/unavailable`: binary missing, unsupported version or contract mismatch.
- `executor/auth_refused`: non-subscription auth route.
- `executor/failed`: the harness reported an error result or exited nonzero.
- `executor/protocol`: malformed or unterminated event stream.
- `executor/deadline`
- `executor/interrupted`: maps to the existing interruption exit codes.
- `candidate/executor_round_limit`
- `candidate/build_blocked`: native builder-reported only.
- The existing `candidate/*` custody stops (`baseline_changed`, `head_moved`, …) apply unchanged after any round.

## 5. Configuration

`.kogen/project.yaml`, on each of `models.shape`, `models.build` and `models.review` independently:

```yaml
models:
  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: high}
  build: {executor: claude-code, model: claude-sonnet-5-5, effort: high, max_rounds: 6}
  review: {executor: claude-code, model: claude-sonnet-5-5, effort: high, max_rounds: 2}
```

- `executor` defaults to `native`, which keeps the existing provider/model/effort semantics.
- `executor: claude-code` forbids `provider`/`base_url`. Model and effort are passed to Claude Code (`--model`, and `--effort` when the installed version supports it).
- `max_rounds` (positive integer, `claude-code` only) caps the rounds of that role's session; the default is 6 per role. Exhaustion stops `candidate/executor_round_limit` with work and evidence preserved. Any other `executor` value is a configuration error.

## 6. Conformance

`cli/executor/conformance` defines **behavior scripts** (JSON) and assertions shared by all executors. Each adapter supplies a driver that makes its backend perform a script: native uses scripted fake-provider responses; claude-code uses a fake `claude` executable that replays the recorded stream-json format. The assertions cover round endings, files, usage state, events, errors, process-group termination and prevention, and they're identical across adapters, except where a capability legitimately differs (asserted from `Describe()`).

Required scripts:
- `finish_after_write`
- `no_call`
- `two_rounds_feedback`
- `protected_write_tool`: prevented when the capability is listed; otherwise left to detection.
- `protected_shell_write`: not prevented; Build-level detection stops it.
- `deadline`
- `interrupt_kills_children`
- `harness_error_result`
- `malformed_stream`: claude only.
- `usage_unknown`
- `auth_route_refused`: claude only.

Build-level guarantees (E1–E3) are tested once in `cli/build` with a fake `Executor`:
- a finish claim on a red tree gets feedback, not a commit;
- a protected mutation stops with `baseline_changed`;
- a HEAD move stops;
- round limit;
- a Claude checkpoint resume is refused;
- the native default is unchanged.

## 7. Pins and cross-repo changes

- kogen-loop is an in-tree synchronized copy at `cli/third_party/kogen-loop/` (`replace kogen-loop => ./third_party/kogen-loop`), written only by `packaging/sync-kogen-loop.sh`.
- `cli/loop-pin.json` records its `protocol`, `library` and source digest, and a test recomputes the digest.
- A kogen-loop change reaches Kogen only as a reviewable copy diff plus a pin update. The copy builds offline and inside Kogen's scratch verification copies.
- An executor contract change updates this file, `executor.go`, the conformance scripts and every adapter driver in the same change.
- The Claude Code adapter records the exact `claude --version` and the init event's reported model and auth route on every run. It refuses versions below its qualified minimum.

## Process-group safety (K-SAFE)

Kogen enforces: a probe (Shape, Refine, or declared feasibility evidence) runs with `KillGroupOnExit` and `RefuseForeignKill`, so a probe command that would stop processes the run did not start (`pkill`, `killall`, `kill` of a foreign pid, decided by the loop's `sys.ForeignKill`) is refused with status 126 and the loop's refusal text, and the round continues. Every other command Kogen runs through `sys.Session.Run` (setup, fix, configured checks, acceptance, hooks, git) sweeps its process group when it ends, without refusing anything. The native builder's `shell` tool is the loop's own: it refuses foreign kills but does not sweep, so background servers outlive a call until round and engine cleanup stop what Kogen started.

Kogen cannot enforce this for the Claude Code executor: its own Bash tool runs outside Kogen's `sys.Session.Run`, so neither refusal nor sweep applies. A Bash `PreToolUse` hook using `sys.ForeignKill` is a separate item, K-SAFE-2. Processes that leave the group with `setsid` are not reached.
