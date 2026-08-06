defmodule CodegenTestHarness.AgentTeardown do
  @moduledoc """
  Teardown helper for the throwaway `Agent`s tests use as call recorders.

  Those agents are started with `Agent.start_link/1` from the test process, so
  they are LINKED to it. ExUnit ends every test with `exit(:shutdown)` on the
  test process (`ExUnit.Runner.spawn_test_monitor/4`), which propagates a
  `:shutdown` exit signal to each linked agent and kills it. That propagation
  is asynchronous with respect to `on_exit/1`, whose callbacks run in a
  separate `ExUnit.OnExitHandler` process.

  So at teardown the agent may be alive, already dead, or dying right now —
  all three are correct. `if Process.alive?(pid), do: Agent.stop(pid)` is a
  check-then-act race: the probe can say "alive" and the process can still be
  gone by the time the `GenServer.stop` call lands, which surfaces as a
  spurious `** (exit) exited in: GenServer.stop(...) ** (EXIT) no process`
  failure on an otherwise passing test.

  `stop_agent/1` catches the exit instead of probing for it, so every ordering
  is tolerated.
  """

  @doc """
  Stops `pid`, tolerating a process that is already dead or dies concurrently.
  """
  @spec stop_agent(pid()) :: :ok
  def stop_agent(pid) when is_pid(pid) do
    Agent.stop(pid)
    :ok
  catch
    # :noproc (already gone) or :normal/:shutdown (died while the call was in
    # flight) — the only outcome teardown cares about is "not running", and
    # all of them satisfy it.
    :exit, _reason -> :ok
  end
end
