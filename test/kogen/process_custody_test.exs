defmodule Kogen.ProcessCustodyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Scenarios `process-custody-teardown` and `stale-lock-and-orphan-sweep`.

  A fake provider (`test/support/fake_orphaning_provider`) ignores stdin EOF
  (never exits on its own, like a hung harness CLI) and forks a grandchild
  that ignores SIGTERM and sleeps, launched through
  `Kogen.ProcessCustody.run/3` — the exact function every real launch site
  (`harness/claude.ex`, `harness/codex.ex`, `Kogen.Build.VerificationRunner`)
  now calls. These tests exercise the shared supervisor
  (`priv/kogen/process_supervisor.py`) and the lock's stale-owner and
  orphan-group sweep directly, without a real harness or provider.
  """

  @provider_script Path.expand("../support/fake_orphaning_provider/provider.sh", __DIR__)

  setup do
    base =
      Path.join(System.tmp_dir!(), "kogen-custody-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp out_dir(base) do
    dir = Path.join(base, "out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp control_dir(base) do
    dir = Path.join(base, "control-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".kogen"))
    dir
  end

  defp alive?(nil), do: false

  defp alive?(pid) do
    match?({_out, 0}, System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  defp wait_until(fun, budget_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    Stream.repeatedly(fn ->
      result = fun.()
      if !result, do: Process.sleep(25)
      result
    end)
    |> Enum.find(fn result -> result || System.monotonic_time(:millisecond) >= deadline end)
  end

  defp wait_for_pid_file(dir, name, budget_ms \\ 5_000) do
    path = Path.join(dir, name)

    wait_until(
      fn ->
        case File.read(path) do
          {:ok, content} -> String.trim(content) != "" and content
          _ -> false
        end
      end,
      budget_ms
    )
    |> case do
      false -> nil
      content -> content |> String.trim() |> String.to_integer()
    end
  end

  # -- process-custody-teardown ----------------------------------------------

  test "a group leader and its SIGTERM-ignoring grandchild both die when the controller tears the group down",
       %{base: base} do
    out = out_dir(base)
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)

    task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!(),
          control: control,
          role: "developer"
        )
      end)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid
    assert alive?(provider_pid)
    assert alive?(grandchild_pid)

    # The group is on the lock before the launch (still running) returns.
    assert wait_until(fn ->
             match?({:ok, %{"groups" => [_ | _]}}, Kogen.ProcessCustody.read_lock(control))
           end)

    reaped = Kogen.ProcessCustody.teardown(control)
    assert reaped != []

    assert {:ok, _facts} = Task.await(task, 5_000)

    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    {:ok, lock} = Kogen.ProcessCustody.read_lock(control)
    assert lock["groups"] == []
  end

  test "a timeout kills the whole group, including the SIGTERM-ignoring grandchild", %{base: base} do
    out = out_dir(base)

    {:ok, facts} =
      Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!(), timeout_ms: 300)

    assert facts["timed_out"] == true

    grandchild_pid = wait_for_pid_file(out, "grandchild.pid", 1_000)
    refute alive?(grandchild_pid)
  end

  test "the supervisor removes the temporary prompt file once the child ends", %{base: base} do
    out = out_dir(base)
    dir = Path.join(base, "stdin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    stdin_path = Path.join(dir, "prompt")
    File.write!(stdin_path, "hello\n")

    task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!(),
          stdin_path: stdin_path
        )
      end)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    assert provider_pid

    System.cmd("/bin/kill", ["-TERM", to_string(provider_pid)], stderr_to_stdout: true)
    Task.await(task, 5_000)

    refute File.exists?(stdin_path)
  end

  test "the parent-death watchdog reaps the group when the controller dies", %{base: base} do
    out = out_dir(base)
    log = Path.join(out, "log")

    controller_port = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["60"]])
    {:os_pid, controller_pid} = Port.info(controller_port, :os_pid)

    spec = %{
      "argv" => [@provider_script, out],
      "cwd" => System.tmp_dir!(),
      "log" => log,
      "mode" => "batch",
      "stdin_path" => nil,
      "tmp_dir" => nil,
      "timeout" => nil,
      "grace" => 0.5,
      "poll" => 0.1,
      "controller_pid" => controller_pid,
      "register_path" => nil
    }

    python3 = System.find_executable("python3") |> to_charlist()

    supervisor_port =
      Port.open({:spawn_executable, python3}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [Kogen.ProcessCustody.supervisor_script_path(), Jason.encode!(spec)]
      ])

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid

    # Simulate `kill -9` of the Kogen controller (BEAM): the fake controller
    # dies without running any Elixir cleanup code.
    System.cmd("/bin/kill", ["-9", to_string(controller_pid)], stderr_to_stdout: true)

    assert wait_until(fn -> !alive?(grandchild_pid) end)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    receive do
      {^supervisor_port, {:exit_status, _}} -> :ok
    after
      2_000 -> :ok
    end
  end

  # -- stale-lock-and-orphan-sweep --------------------------------------------

  test "a stale lock with a live orphan group is reaped and reclaimed at Build start", %{
    base: base
  } do
    out = out_dir(base)
    control = control_dir(base)

    # A live group not torn down by anyone (a previous controller that died
    # without running its watchdog or teardown).
    orphan_task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!())
      end)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid

    stale_lock = %{
      "pid" => 999_999,
      "started_at" => "Thu Jan  1 00:00:00 1970",
      "build_id" => "stale-build",
      "groups" => [
        %{
          "pid" => provider_pid,
          "pgid" => provider_pid,
          "started_at" => Kogen.ProcessCustody.process_start(provider_pid),
          "role" => "developer"
        }
      ]
    }

    File.write!(Kogen.ProcessCustody.lock_path(control), Jason.encode!(stale_lock))

    assert {:ok, {:reclaimed, reaped}} = Kogen.ProcessCustody.acquire(control)
    assert reaped != []

    assert wait_until(fn -> !alive?(grandchild_pid) end)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    {:ok, lock} = Kogen.ProcessCustody.read_lock(control)
    assert lock["groups"] == []
    refute lock["build_id"]

    # The orphaned launch's own `run/3` call returns once its group is gone.
    Task.await(orphan_task, 5_000)
  end

  test "a live owner's lock refuses a new Build", %{base: base} do
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)

    assert {:error, reason} = Kogen.ProcessCustody.acquire(control)
    assert reason =~ "build lock already present"
  end

  test "a group whose pid was reused (start time mismatch) is left alone", %{base: base} do
    control = control_dir(base)

    unrelated = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["30"]])
    {:os_pid, unrelated_pid} = Port.info(unrelated, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-9", to_string(unrelated_pid)], stderr_to_stdout: true)
    end)

    stale_lock = %{
      "pid" => 999_999,
      "started_at" => "Thu Jan  1 00:00:00 1970",
      "build_id" => "stale-build",
      "groups" => [
        %{
          "pid" => unrelated_pid,
          "pgid" => unrelated_pid,
          "started_at" => "Thu Jan  1 00:00:00 1970",
          "role" => "developer"
        }
      ]
    }

    File.write!(Kogen.ProcessCustody.lock_path(control), Jason.encode!(stale_lock))

    assert {:ok, {:reclaimed, _reaped}} = Kogen.ProcessCustody.acquire(control)
    assert alive?(unrelated_pid)

    Port.close(unrelated)
  end

  # -- real controller, real exit paths ---------------------------------------
  #
  # A small controller stand-in (`test/support/custody_controller_standin.exs`)
  # runs as a real, separate `mix run` OS process: it calls the exact
  # production `Kogen.ProcessCustody.acquire/1`/`run/3`/`release/1`, and, in
  # "hang" mode, installs the real `mix kogen.build` signal trap
  # (`Mix.Tasks.Kogen.Build.SignalHandler`). These tests end that process
  # through SIGHUP, SIGTERM, `kill -9` and Ctrl-C under a pty with
  # `ELIXIR_ERL_OPTIONS=+Bd`, and drive a normal stop and a timeout, then
  # assert the fake provider's group and its SIGTERM-ignoring grandchild are
  # gone within a bounded wait and the lock is released or reclaimable. Only
  # the process this test itself started (and its own descendants) is ever
  # killed.

  defp mix_executable, do: System.find_executable("mix") || raise("mix not found on PATH")

  defp start_standin(mode, control, out) do
    port =
      Port.open(
        {:spawn_executable, mix_executable() |> to_charlist()},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: [
            "run",
            Path.expand("../support/custody_controller_standin.exs", __DIR__),
            mode,
            control,
            out
          ],
          env: [{~c"FAKE_PROVIDER", String.to_charlist(@provider_script)}]
        ]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert wait_for_standin_ready(port, "")
    %{port: port, pid: pid}
  end

  defp wait_for_standin_ready(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if acc =~ "READY", do: true, else: wait_for_standin_ready(port, acc)

      {^port, {:exit_status, _status}} ->
        false
    after
      10_000 -> false
    end
  end

  defp drain_standin(port, budget_ms \\ 5_000) do
    receive do
      {^port, {:data, _data}} -> drain_standin(port, budget_ms)
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      budget_ms -> :timeout
    end
  end

  for {label, signal} <- [{"SIGHUP", "-HUP"}, {"SIGTERM", "-TERM"}] do
    test "a real controller torn down by #{label} reaps its group and releases the lock", %{
      base: base
    } do
      out = out_dir(base)
      control = control_dir(base)

      standin = start_standin("hang", control, out)
      provider_pid = wait_for_pid_file(out, "provider.pid")
      grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
      assert provider_pid && grandchild_pid

      System.cmd("/bin/kill", [unquote(signal), to_string(standin.pid)], stderr_to_stdout: true)

      assert wait_until(fn -> !alive?(standin.pid) end)
      assert wait_until(fn -> !alive?(grandchild_pid) end)
      refute alive?(provider_pid)
      refute alive?(grandchild_pid)
      refute File.exists?(Kogen.ProcessCustody.lock_path(control))
    end
  end

  test "a real controller killed with kill -9 leaves a reclaimable lock, reaped by the next acquire",
       %{base: base} do
    out = out_dir(base)
    control = control_dir(base)

    standin = start_standin("hang", control, out)
    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid

    System.cmd("/bin/kill", ["-9", to_string(standin.pid)], stderr_to_stdout: true)

    assert wait_until(fn -> !alive?(standin.pid) end)
    assert wait_until(fn -> !alive?(grandchild_pid) end)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    # The lock is stale (its owner, the killed standin, is dead) but still
    # present; the next Build reclaims it, printing one line naming what it
    # reaped (nothing live, since the watchdog already won the race).
    assert {:ok, {:reclaimed, _reaped}} = Kogen.ProcessCustody.acquire(control)
  end

  @tag :unconfined
  test "Ctrl-C under a pty with ELIXIR_ERL_OPTIONS=+Bd exits at once, and the watchdog still reaps the group",
       %{base: base} do
    out = out_dir(base)
    control = control_dir(base)

    driver = Path.expand("../support/pty_ctrlc.py", __DIR__)
    standin = Path.expand("../support/custody_controller_standin.exs", __DIR__)

    {output, 0} =
      System.cmd(
        "python3",
        [driver, mix_executable(), standin, "hang", control, out, @provider_script],
        stderr_to_stdout: true
      )

    assert output =~ ~r/exited=\d/

    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    provider_pid = wait_for_pid_file(out, "provider.pid")
    assert grandchild_pid && provider_pid

    assert wait_until(fn -> !alive?(grandchild_pid) end)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    assert {:ok, {:reclaimed, _reaped}} = Kogen.ProcessCustody.acquire(control)
  end

  test "a real controller's normal Stop tears its own groups down and releases the lock", %{
    base: base
  } do
    out = out_dir(base)
    control = control_dir(base)

    standin = start_standin("stop", control, out)
    assert {:ok, 0} = drain_standin(standin.port)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)
    refute File.exists?(Kogen.ProcessCustody.lock_path(control))
  end

  test "a real controller's timeout kills the whole group and releases the lock", %{base: base} do
    out = out_dir(base)
    control = control_dir(base)

    standin = start_standin("timeout", control, out)
    assert {:ok, 0} = drain_standin(standin.port)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)
    refute File.exists?(Kogen.ProcessCustody.lock_path(control))
  end
end
