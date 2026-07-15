defmodule Mix.Tasks.Codegen.Loop.Queue do
  @shortdoc "Drains codegen/pitches/ready/ — one fresh isolated build per pitch."

  @moduledoc """
  `mix codegen.loop.queue --harness=<claude|pi> --stack=<phoenix|static> --cwd=<dir>`

  Multi-pitch driver invoked by `claude-build --queue` / `pi-build --queue`.
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

  - `--harness` — required, `claude` | `pi`
  - `--stack` — required, e.g. `phoenix` | `static`
  - `--cwd` — required, project directory whose `codegen/pitches/ready/` is drained

  ## Operator toggles (build-time; read by the drain, not this task)

  - `CODEGEN_BUILD_QUEUE_MAX_RETRIES` — max consecutive transient retries per slug (default 3)
  - `CODEGEN_BUILD_QUEUE_RETRY_DELAYS` — space-separated backoff seconds (default "30 120 300")
  - `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS` — per-pitch wall-clock budget seconds (default 7200)
  - `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS` — consecutive deterministic
    pitch failures (no ship in between) at which the drain HALTs instead of
    skipping-and-continuing (default 3)
  """

  use Mix.Task

  alias CodegenTestHarness.BuildSignalHandler
  alias CodegenTestHarness.LoopQueueDrain

  @impl Mix.Task
  @spec run([String.t()]) :: no_return() | :ok
  def run(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv, strict: [harness: :string, stack: :string, cwd: :string])

    if invalid != [] do
      Mix.shell().error("codegen.loop.queue: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    harness = Keyword.get(opts, :harness) || missing_flag!("--harness")
    stack = Keyword.get(opts, :stack) || missing_flag!("--stack")
    cwd = Keyword.get(opts, :cwd) || missing_flag!("--cwd")

    # Move 2: install the SIGTERM handler BEFORE the drain acquires its lock
    # or spawns anything — a Ctrl-C landing before the first pitch even
    # starts must still be handled cleanly (no-op reap, clean exit). SIGINT
    # itself cannot be caught at the BEAM level (see BuildSignalHandler
    # moduledoc); the bash dispatch layer traps INT and forwards SIGTERM to
    # this process group so this handler still runs on Ctrl-C.
    lock_path = Path.join([cwd, "codegen", "gate-pending", "queue.lock"])
    :ok = BuildSignalHandler.install(lock_path)

    unless harness in ["claude", "pi"] do
      Mix.shell().error(
        "codegen.loop.queue: --harness must be \"claude\" or \"pi\", got #{inspect(harness)}"
      )

      exit({:shutdown, 2})
    end

    case LoopQueueDrain.drain(harness: harness, stack: stack, cwd: cwd) do
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
