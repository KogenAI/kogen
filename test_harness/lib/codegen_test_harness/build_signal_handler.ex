defmodule CodegenTestHarness.BuildSignalHandler do
  @moduledoc """
  Installs a `:gen_event` handler on Erlang's `:erl_signal_server` so SIGTERM
  tears down an in-flight build's spawned process tree BEFORE the BEAM halts
  — closing the gap the moduledoc invariant names: "a build's process tree
  dies with the run that spawned it — on interrupt, on crash, on exit — and
  no run ever begins while a previous run's tree is still alive."

  ## SIGINT cannot be caught here — real-contract probe result

  Erlang's `:os.set_signal/2` accepts only
  `{sighup, sigquit, sigabrt, sigalrm, sigterm, sigusr1, sigusr2, sigchld,
  sigstop, sigtstp, sigcont, sigwinch, siginfo}` — `:sigint` is NOT in that
  set (`:os.set_signal(:sigint, :handle)` raises
  `ArgumentError: invalid signal name` on every call, confirmed by a live
  probe against this OTP release). `System.trap_signal/3` has the identical
  exclusion. Ctrl-C (SIGINT) is intercepted by Erlang's own built-in
  break-handler before any `:gen_event` handler can observe it — there is no
  BEAM-level hook for it, on this or any OTP release.

  Consequently SIGINT teardown is NOT this module's job: it is handled one
  layer down, in the bash dispatch scripts (`harnesses/claude/dispatch.sh`,
  `harnesses/pi/dispatch.sh`), which run the loop as a job-controlled child
  (`set -m`) and `trap` INT to forward `SIGTERM` to the child's process
  group — SIGTERM IS catchable here, so that forwarded signal reaches this
  handler exactly the same way a direct SIGTERM would. This module handles
  SIGTERM only; it does not attempt SIGINT.

  Without this handler, `:os.set_signal(:sigterm, :handle)` defaults to
  `:default` for SIGTERM, which lets the BEAM terminate immediately without
  running any `after` block — orphaning whatever
  `CodegenTestHarness.LoopQueueDrain.default_spawn_fn/5` spawned (reparented
  to init, PPID=1, still billing, still editing the repo). Both
  `mix codegen.loop.queue` and `mix codegen.loop` install this handler at
  the very start of their `run/1`.

  ## Contract

  - First SIGTERM (including one forwarded by the bash dispatch layer's own
    INT trap): reap the in-flight tree (via `reap_fn`, default
    `LoopQueueDrain.reap_in_flight_tree/0`), release the lock (via
    `release_fn`, default `BuildLock.release/1`), print a one-line notice on
    stderr, then `:erlang.halt(130)` (128 + SIGINT's signal number 2 — the
    conventional shell exit code for "killed by Ctrl-C", kept even though
    this handler itself only ever observes SIGTERM, since the operator-
    visible trigger for this path is overwhelmingly Ctrl-C forwarded from
    bash).
  - Second signal while still tearing down: hard-`:erlang.halt(130)`
    IMMEDIATELY, no reap wait — an operator who presses Ctrl-C twice must
    never be stuck waiting on a teardown that itself hangs.
  - Installed once per BEAM (idempotent — installing twice is guarded by
    `:gen_event.which_handlers/1` membership check, so a re-run inside the
    same VM, e.g. under `iex`, never double-installs).

  This is a THIN wrapper — the actual reap logic
  (`LoopQueueDrain.reap_in_flight_tree/0`) is unchanged and shared with the
  Move 1 exit-path caller; this module's only job is turning a SIGTERM into
  a call to that existing, tested function before halting.
  """

  @behaviour :gen_event

  alias CodegenTestHarness.BuildLock

  @halt_code 130

  @doc """
  Installs the signal handler for `lock_path` (released on signal receipt).
  `reap_fn` / `release_fn` / `halt_fn` are test seams (default to the real
  reap, `BuildLock.release/1`, and `:erlang.halt/1` respectively) — override
  in tests so a signal-handling test never actually halts the test BEAM.

  Only `:sigterm` is registered with `:os.set_signal/2` — `:sigint` is
  excluded from Erlang's settable-signal set on every OTP release (see
  moduledoc); attempting `:os.set_signal(:sigint, :handle)` raises
  `ArgumentError`. SIGINT teardown is handled by the bash dispatch layer
  forwarding SIGTERM to this BEAM's process group (see moduledoc).

  Idempotent: installing while an instance of this handler is already
  registered on `:erl_signal_server` is a no-op (returns `:ok` either way).
  """
  @spec install(String.t(), keyword()) :: :ok
  def install(lock_path, opts \\ []) do
    :ok = :os.set_signal(:sigterm, :handle)

    already_installed? =
      :erl_signal_server
      |> :gen_event.which_handlers()
      |> Enum.any?(&match?(__MODULE__, &1))

    if already_installed? do
      :ok
    else
      state = %{
        lock_path: lock_path,
        reap_fn: Keyword.get(opts, :reap_fn, &default_reap_fn/0),
        release_fn: Keyword.get(opts, :release_fn, &BuildLock.release/1),
        halt_fn: Keyword.get(opts, :halt_fn, &default_halt_fn/1),
        tearing_down?: false
      }

      :gen_event.add_handler(:erl_signal_server, __MODULE__, state)
    end
  end

  @doc "Uninstalls the handler (test cleanup — never called in production)."
  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    :gen_event.delete_handler(:erl_signal_server, __MODULE__, [])
  end

  @impl :gen_event
  def init(state), do: {:ok, state}

  # Second signal mid-teardown: hard-halt immediately, no reap wait — an
  # operator pressing Ctrl-C twice must never be stuck waiting on a
  # teardown that itself hangs.
  @impl :gen_event
  def handle_event(signal, %{tearing_down?: true} = state) when signal == :sigterm do
    IO.puts(:stderr, "queue: second signal received — hard exit, no reap wait")
    state.halt_fn.(@halt_code)
    {:ok, state}
  end

  def handle_event(signal, %{tearing_down?: false} = state) when signal == :sigterm do
    IO.puts(:stderr, "queue: #{signal} received — reaping in-flight build tree")
    state = %{state | tearing_down?: true}

    state.reap_fn.()

    case state.release_fn.(state.lock_path) do
      :ok -> :ok
      # fail-loud-exempt: lock release is best-effort during teardown — a
      # failure here must not block the halt that follows; the lock file
      # naming a now-dead pid is reclaimed as stale on the next acquire
      # regardless (BuildLock.acquire/3's existing stale-lock recovery).
      _ -> :ok
    end

    state.halt_fn.(@halt_code)
    {:ok, state}
  end

  def handle_event(_other, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_msg, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  defp default_reap_fn do
    CodegenTestHarness.LoopQueueDrain.reap_in_flight_tree()
  end

  defp default_halt_fn(code), do: :erlang.halt(code)
end
