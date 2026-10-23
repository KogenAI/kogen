defmodule KogenCheckGateReporter do
  use GenServer

  def init(_opts) do
    {:ok, %{active: MapSet.new(), modulePeak: 0, passed: 0, failed: 0, invalid: 0, skipped: 0, excluded: 0, tests: %{}}}
  end

  def handle_cast({:module_started, mod}, state) do
    active = MapSet.put(state.active, mod.name)
    {:noreply, %{state | active: active, modulePeak: max(state.modulePeak, MapSet.size(active))}}
  end

  def handle_cast({:module_finished, mod}, state) do
    {:noreply, %{state | active: MapSet.delete(state.active, mod.name)}}
  end

  def handle_cast({:test_finished, test}, state) do
    result = case test.state do
      nil -> :passed
      {:failed, _} -> :failed
      {:invalid, _} -> :invalid
      {:skipped, _} -> :skipped
      {:excluded, _} -> :excluded
    end
    name = test.name |> Atom.to_string() |> String.replace_prefix("test ", "")
    state = Map.update!(state, result, &(&1 + 1))
    {:noreply, %{state | tests: Map.put(state.tests, name, Atom.to_string(result))}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    IO.puts("CHECK_GATE_SUITE=" <> JSON.encode!(Map.delete(state, :active)))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end

defmodule KogenCheckGateMeasurement do
  alias Kogen.Integration.{Helpers, FakeProvider}

  def alive?(pid) do
    {_output, code} = System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    code == 0
  end

  def signal(pid, name) do
    System.cmd("/bin/kill", ["-" <> name, to_string(pid)], stderr_to_stdout: true)
  end

  def wait_dead(pid, deadline) do
    if alive?(pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      wait_dead(pid, deadline)
    end
  end

  # This finalizer is scoped to recorded fixture PIDs. It is not the behavior
  # under test and never changes the receipt collected immediately after cleanup.
  def final_cleanup(c, cli, child) do
    signal(cli, "TERM")
    deadline = System.monotonic_time(:millisecond) + 16000
    wait_dead(cli, deadline)
    wait_dead(child, deadline)
    if alive?(child), do: signal(child, "KILL")
    if alive?(cli), do: signal(cli, "KILL")
    FakeProvider.stop(c.server)
    try do
      Agent.stop(c.ports)
    catch
      :exit, _ -> :ok
    end
    File.rm_rf(c.root)
  end

  def owner_case(suite, how) do
    parent = self()
    {owner, monitor} = spawn_monitor(fn ->
      c = Helpers.project!(suite, [], staged_intent: false)
      child_file = Path.join(c.repo, ".kogen/local/owned-child")
      heartbeat = Path.join(c.repo, ".kogen/local/heartbeat")
      quote = &Kogen.Init.shell_quote/1
      command = "trap 'exit 0' TERM INT; echo $$ > #{quote.(child_file)}; while :; do printf alive > #{quote.(heartbeat)}; sleep 0.05; done"
      FakeProvider.append(c.server, [{:function, "shell", %{"command" => command}}])
      port = Helpers.start_kogen(c, ["intent", "build", "fixture"])
      {:os_pid, cli} = Port.info(port, :os_pid)
      Helpers.wait_for_file!(child_file, 60000)
      child = child_file |> File.read!() |> String.trim() |> String.to_integer()
      send(parent, {:owned_running, c, cli, child})
      receive do
        :finish -> exit(:shutdown)
      end
    end)

    {c, cli, child} = receive do
      {:owned_running, c, cli, child} -> {c, cli, child}
      {:DOWN, ^monitor, :process, ^owner, reason} -> raise("fixture startup failed: #{inspect(reason)}")
    after
      180000 -> raise("fixture startup did not finish")
    end

    unrelated = Port.open({:spawn_executable, ~c"/bin/sleep"}, [:exit_status, {:args, [~c"600"]}])
    {:os_pid, other} = Port.info(unrelated, :os_pid)
    try do
      started = alive?(cli) and alive?(child) and File.dir?(c.root)
      if how == :normal, do: send(owner, :finish), else: Process.exit(owner, :kill)
      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
      after
        60000 -> raise("fixture owner did not terminate")
      end
      cleanup_returned = try do
        Helpers.cleanup_case(c)
        true
      rescue
        _error -> false
      catch
        :exit, _reason -> false
      end
      %{
        started: started,
        cleanupReturned: cleanup_returned,
        cliStopped: not alive?(cli),
        childStopped: not alive?(child),
        rootRemoved: not File.exists?(c.root),
        unrelatedAlive: alive?(other)
      }
    after
      final_cleanup(c, cli, child)
      signal(other, "TERM")
      if Port.info(unrelated) != nil, do: Port.close(unrelated)
    end
  end

  def measure do
    ExUnit.start(autorun: false)
    Code.require_file(Path.expand("test/support/integration_helpers.ex"))
    suite = Helpers.setup_suite!()
    try do
      marker = Path.join(suite.root, "delayed-marker")
      {timer, ref} = spawn_monitor(fn ->
        Process.sleep(11000)
        File.write!(marker, "ready")
      end)
      delayed = try do
        Helpers.wait_for_file!(marker)
        File.read!(marker) == "ready"
      rescue
        _error -> false
      end
      receive do
        {:DOWN, ^ref, :process, ^timer, :normal} -> :ok
      after
        30000 -> raise("delayed marker fixture did not finish")
      end
      missing_path = Path.join(suite.root, "genuinely-missing-marker")
      missing = try do
        Helpers.wait_for_file!(missing_path, 50)
        false
      rescue
        error -> String.contains?(Exception.message(error), missing_path)
      end
      report = %{delayedMarker: delayed, missingMarker: missing,
        normal: owner_case(suite, :normal), aborted: owner_case(suite, :aborted)}
      IO.puts("CHECK_GATE_LIFECYCLE=" <> JSON.encode!(report))
    after
      Helpers.cleanup_suite(suite)
      ExUnit.run()
    end
  end
end

if System.argv() == ["measure"], do: KogenCheckGateMeasurement.measure()
