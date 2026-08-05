defmodule Mix.Tasks.Codegen.Loop.Queue do
  @shortdoc "Drains codegen/pitches/ready/ — one fresh isolated build per pitch."

  @moduledoc """
  `mix codegen.loop.queue --harness=claude --stack=<phoenix|static> --cwd=<dir>`

  Multi-pitch driver invoked by `claude-build --queue`.
  Delegates to `CodegenTestHarness.LoopQueueDrain.drain/1`, which spawns one
  fresh isolated `codegen-build` child per ordered pitch under
  `<cwd>/codegen/pitches/ready/`, moving each to `shipped/` on success.

  Exits:

  - `0` — drain returned `{:ok, n}` (n pitches shipped, `ready/` empty).
    Isolated deterministic failures below the consecutive-failure circuit
    breaker are tolerated here too — the failed pitch is skipped-and-left in
    `ready/`, not a drain failure (see `LoopQueueDrain` moduledoc).
  - non-zero, reason on stderr — `{:error, reason}` (circuit-breaker trip —
    too many consecutive deterministic failures, an orphaned base, or lock
    contention)

  A dependency cycle among the batch (the `blocks_on:` frontmatter graph,
  or legacy `Blocks-on:` prose graph when no frontmatter is present) is NOT
  caught here — `LoopQueueDrain.drain/1` lets it raise, crashing this task
  loud (non-zero exit) rather than picking an arbitrary order.

  ## Flags

  - `--harness` — required, `claude`
  - `--stack` — required, e.g. `phoenix` | `static`
  - `--cwd` — required, project directory whose `codegen/pitches/ready/` is drained
  - `--watch` — optional. When `ready/` empties, do not exit — sleep and
    keep scanning so a pitch that arrives later (e.g. via `scp` from
    another machine) is picked up without a human relaunching the node.
    See `CodegenTestHarness.LoopQueueDrain` moduledoc "`:watch`". Every
    other exit (Ctrl-C, spend ceiling, consecutive-fail breaker,
    orphan/infra abort) is unchanged.

  ## Operator toggles (build-time; read by the drain, not this task)

  - `CODEGEN_BUILD_QUEUE_MAX_RETRIES` — max consecutive transient retries per slug (default 3)
  - `CODEGEN_BUILD_QUEUE_RETRY_DELAYS` — space-separated backoff seconds (default "30 120 300")
  - `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS` — per-pitch wall-clock budget seconds (default 7200)
  - `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS` — consecutive deterministic
    pitch failures (no ship in between) at which the drain HALTs instead of
    skipping-and-continuing (default 3)
  - `CODEGEN_BUILD_QUEUE_BUDGET_USD` — queue-WIDE spend ceiling in USD,
    checked BEFORE spawning each pitch (the in-flight pitch always
    completes; only pitches AFTER it are bounded). Absent/unparseable ->
    `nil` -> unlimited, exactly today's behavior — no default. Every drain,
    capped or not, prints its accumulated total spend on every terminal
    path (`queue: N shipped, M failed, $X.XX total`). A child that concludes
    with no readable cost (killed/timed out before emitting its result
    record) is UNACCOUNTABLE spend: under an active ceiling the drain halts
    rather than risk sailing past it; with no ceiling set it is merely
    unreported, byte-for-byte today's behavior.
  - `CODEGEN_BUILD_QUEUE_POLL_SECS` — `--watch`-only: seconds slept between
    empty-`ready/` scans (default 60).
  - `CODEGEN_BUILD_QUEUE_QUIESCE_SECS` — `--watch`-only: a `.md` in
    `ready/` whose mtime is newer than this many seconds ago is treated as
    not-yet-arrived (default 30) — guards against selecting a pitch
    mid-`scp`.
  """

  use Mix.Task

  alias CodegenTestHarness.BuildSignalHandler
  alias CodegenTestHarness.LoopQueueDrain

  @impl Mix.Task
  @spec run([String.t()]) :: no_return() | :ok
  def run(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv,
        strict: [harness: :string, stack: :string, cwd: :string, watch: :boolean]
      )

    if invalid != [] do
      Mix.shell().error("codegen.loop.queue: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    harness = Keyword.get(opts, :harness) || missing_flag!("--harness")
    stack = Keyword.get(opts, :stack) || missing_flag!("--stack")
    cwd = Keyword.get(opts, :cwd) || missing_flag!("--cwd")
    watch = Keyword.get(opts, :watch, false)

    # Move 2: install the SIGTERM handler BEFORE the drain acquires its lock
    # or spawns anything — a Ctrl-C landing before the first pitch even
    # starts must still be handled cleanly (no-op reap, clean exit). SIGINT
    # itself cannot be caught at the BEAM level (see BuildSignalHandler
    # moduledoc); the shared harnesses/shared/loop-signal-bridge.sh helper,
    # sourced by this --queue leg's bash launcher, traps INT and forwards a
    # group SIGTERM so this handler still runs on Ctrl-C.
    lock_path = Path.join([cwd, "codegen", "gate-pending", "queue.lock"])
    :ok = BuildSignalHandler.install(lock_path)

    unless harness in ["claude"] do
      Mix.shell().error(
        "codegen.loop.queue: --harness must be \"claude\", got #{inspect(harness)}"
      )

      exit({:shutdown, 2})
    end

    case LoopQueueDrain.drain(harness: harness, stack: stack, cwd: cwd, watch: watch) do
      {:ok, n} ->
        Mix.shell().info("codegen.loop.queue: #{n} shipped")
        :ok

      {:error, reason} ->
        Mix.shell().error("codegen.loop.queue: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp missing_flag!(name) do
    Mix.shell().error("codegen.loop.queue: #{name} is required")
    exit({:shutdown, 2})
  end
end
