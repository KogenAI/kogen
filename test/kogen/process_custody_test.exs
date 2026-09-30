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

  test "release cannot race a finishing group into recreating the lock", %{base: base} do
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)
    Kogen.ProcessCustody.claim(control, "regression")
    path = Kogen.ProcessCustody.lock_path(control)
    parent = self()
    ref = make_ref()

    Kogen.ProcessCustody.set_forget_group_hook(control, fn _control ->
      send(parent, {:paused_after_read, ref})

      receive do
        {:continue_forget, ^ref} -> :ok
      end
    end)

    Kogen.ProcessCustody.set_release_wait_hook(control, fn ->
      send(parent, {:release_waiting_for_lock, ref})
    end)

    on_exit(fn ->
      Kogen.ProcessCustody.clear_forget_group_hook(control)
      Kogen.ProcessCustody.clear_release_wait_hook(control)
    end)

    forget_task = Task.async(fn -> Kogen.ProcessCustody.forget_group(control, 123) end)
    assert_receive {:paused_after_read, ^ref}, 1_000

    release_task = Task.async(fn -> Kogen.ProcessCustody.release(control) end)

    assert wait_until(
             fn ->
               receive do
                 {:release_waiting_for_lock, ^ref} -> true
               after
                 0 -> not File.exists?(path)
               end
             end,
             1_000
           )

    send(forget_task.pid, {:continue_forget, ref})
    assert :ok = Task.await(forget_task, 5_000)
    assert :ok = Task.await(release_task, 5_000)
    refute File.exists?(path)
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

  test "a turn reaps a descendant that starts a new session", %{base: base} do
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)
    child_file = Path.join(base, "detached.pid")

    script =
      "import os,time; child=os.fork(); (os.setsid(), open(#{inspect(child_file)}, 'w').write(str(os.getpid())), time.sleep(30)) if child == 0 else time.sleep(0.5)"

    assert {:ok, %{"exit_code" => 0}} =
             Kogen.ProcessCustody.run([System.find_executable("python3"), "-c", script], base,
               control: control,
               role: "detached-test"
             )

    detached_pid = child_file |> File.read!() |> String.to_integer()
    refute alive?(detached_pid)
  end

  test "concurrent runs reap detached children and clear their shared lock records", %{
    base: base
  } do
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)

    on_exit(fn ->
      Kogen.ProcessCustody.clear_signal_hook(control)
      Kogen.ProcessCustody.release(control)
    end)

    child_files = Enum.map(1..4, &Path.join(base, "concurrent-detached-#{&1}.pid"))

    tasks =
      Enum.map(child_files, fn child_file ->
        script =
          """
          import json, os, time
          child = os.fork()
          if child == 0:
              os.setsid()
              open(#{inspect(child_file)}, 'w').write(str(os.getpid()))
              time.sleep(30)
          else:
              recorded = False
              for _ in range(250):
                  try:
                      lock = json.load(open(#{inspect(Kogen.ProcessCustody.lock_path(control))}))
                      recorded = any(descendant.get('pid') == child
                                     for group in lock.get('groups', [])
                                     for descendant in group.get('descendants', []))
                  except (FileNotFoundError, json.JSONDecodeError):
                      pass
                  if recorded:
                      break
                  time.sleep(0.02)
              if not recorded:
                  raise RuntimeError('detached child was not recorded')
          """

        Task.async(fn ->
          Kogen.ProcessCustody.run(
            [System.find_executable("python3"), "-c", script],
            base,
            control: control,
            role: "concurrent-detached"
          )
        end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 8_000))
    assert Enum.all?(results, &match?({:ok, %{"exit_code" => 0}}, &1))

    child_pids =
      Enum.map(child_files, fn child_file ->
        assert wait_until(fn -> File.exists?(child_file) end, 2_000)
        child_file |> File.read!() |> String.to_integer()
      end)

    assert wait_until(fn -> Enum.all?(child_pids, &(not alive?(&1))) end, 3_000)
    assert {:ok, %{"groups" => []}} = Kogen.ProcessCustody.read_lock(control)
  end

  test "a supervised command may run before a build lock is acquired", %{base: base} do
    control = control_dir(base)
    marker = Path.join(base, "started")
    script = "open(#{inspect(marker)}, 'w').write('started')"

    assert {:ok, %{"exit_code" => 0}} =
             Kogen.ProcessCustody.run([System.find_executable("python3"), "-c", script], base,
               control: control,
               role: "missing-lock"
             )

    assert File.exists?(marker)
  end

  test "a failed registration reaps only its own group and leaves a sibling alive", %{
    base: base
  } do
    control = control_dir(base)
    sibling_out = out_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)

    on_exit(fn ->
      File.chmod(Kogen.ProcessCustody.lock_path(control), 0o600)
      Kogen.ProcessCustody.clear_signal_hook(control)
      Kogen.ProcessCustody.release(control)
    end)

    sibling_task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([@provider_script, sibling_out], System.tmp_dir!(),
          control: control,
          role: "registration-sibling"
        )
      end)

    sibling_pid = wait_for_pid_file(sibling_out, "provider.pid")
    assert sibling_pid

    assert wait_until(fn ->
             match?({:ok, %{"groups" => [_]}}, Kogen.ProcessCustody.read_lock(control))
           end)

    parent = self()

    Kogen.ProcessCustody.set_signal_hook(control, fn
      :group, pgid, signal ->
        send(parent, {:registration_abort_signal, pgid, signal})
        :continue

      _target_type, _target, _signal ->
        :continue
    end)

    # Registration itself is readable, but recording its group fails at the
    # lock write. The old abort path called teardown/1 here and killed the
    # already registered sibling group too.
    :ok = File.chmod(Kogen.ProcessCustody.lock_path(control), 0o444)
    marker = Path.join(base, "failed-registration-command-ran")
    script = "open(#{inspect(marker)}, 'w').write('started')"

    failed_run =
      Task.async(fn ->
        Kogen.ProcessCustody.run(
          [System.find_executable("python3"), "-c", script],
          base,
          control: control,
          role: "registration-failure"
        )
      end)

    assert {:error, reason} = Task.await(failed_run, 8_000)
    assert reason =~ "process supervision setup failed"
    assert_receive {:registration_abort_signal, aborted_pgid, :term}, 1_000
    refute aborted_pgid == sibling_pid
    refute File.exists?(marker)
    assert alive?(sibling_pid)

    assert {:ok, %{"groups" => [%{"pid" => ^sibling_pid}]}} =
             Kogen.ProcessCustody.read_lock(control)

    :ok = File.chmod(Kogen.ProcessCustody.lock_path(control), 0o600)
    Kogen.ProcessCustody.clear_signal_hook(control)
    assert :ok = Kogen.ProcessCustody.release(control)
    assert {:ok, _facts} = Task.await(sibling_task, 5_000)
    refute alive?(sibling_pid)
  end

  test "denied group signals return cleanup failure and retain the live group record", %{
    base: base
  } do
    out = out_dir(base)
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)

    Kogen.ProcessCustody.set_cleanup_grace_ms(control, 300)

    on_exit(fn ->
      Kogen.ProcessCustody.clear_cleanup_grace_ms(control)
      Kogen.ProcessCustody.clear_signal_hook(control)
      Kogen.ProcessCustody.release(control)
    end)

    run_task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!(),
          control: control,
          role: "denied-signal"
        )
      end)

    provider_pid = wait_for_pid_file(out, "provider.pid")
    assert provider_pid

    test_pid = self()

    Kogen.ProcessCustody.set_signal_hook(control, fn
      :group, ^provider_pid, signal ->
        send(test_pid, {:denied_group_signal, signal})
        {:error, :eperm}

      _target_type, _target, _signal ->
        :continue
    end)

    assert {:error, reason} = Kogen.ProcessCustody.teardown(control)

    assert reason =~ "could not reap process groups"

    # Teardown is bounded by its own escalation, not by a clock: it returned
    # after a single graceful signal followed by a single forced one, and never
    # signalled the denied group again.
    signals = collect_denied_group_signals([])
    assert length(signals) == length(Enum.uniq(signals))
    assert length(signals) >= 2
    assert alive?(provider_pid)
    assert {:ok, %{"groups" => [_retained_group]}} = Kogen.ProcessCustody.read_lock(control)

    Kogen.ProcessCustody.clear_signal_hook(control)
    assert :ok = Kogen.ProcessCustody.release(control)
    assert {:ok, _facts} = Task.await(run_task, 5_000)
    refute alive?(provider_pid)
  end

  defp collect_denied_group_signals(acc) do
    receive do
      {:denied_group_signal, signal} -> collect_denied_group_signals(acc ++ [signal])
    after
      0 -> acc
    end
  end

  test "a denied escaped child keeps its record but not a live descendant monitor", %{base: base} do
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)
    parent = self()

    # Denied TERM and KILL each wait a full settle grace; shorten it so the
    # awaited work is bounded by events, not by 2 x 2 s of fixed waits.
    Kogen.ProcessCustody.set_cleanup_grace_ms(control, 300)

    Kogen.ProcessCustody.set_monitor_stop_hook(control, fn root_pid ->
      send(parent, {:descendant_monitor_stopped, root_pid})
    end)

    on_exit(fn ->
      Kogen.ProcessCustody.clear_signal_hook(control)
      Kogen.ProcessCustody.clear_cleanup_grace_ms(control)
      Kogen.ProcessCustody.clear_monitor_stop_hook(control)
      Kogen.ProcessCustody.release(control)
    end)

    child_file = Path.join(base, "denied-detached.pid")

    script =
      "import os,time; child=os.fork(); (os.setsid(), open(#{inspect(child_file)}, 'w').write(str(os.getpid())), time.sleep(30)) if child == 0 else time.sleep(0.35)"

    run_task =
      Task.async(fn ->
        Kogen.ProcessCustody.run([System.find_executable("python3"), "-c", script], base,
          control: control,
          role: "denied-detached"
        )
      end)

    child_pid =
      wait_until(
        fn ->
          case File.read(child_file) do
            {:ok, contents} -> String.trim(contents) != "" and contents
            _ -> false
          end
        end,
        2_000
      )
      |> case do
        false -> nil
        contents -> contents |> String.trim() |> String.to_integer()
      end

    assert child_pid

    Kogen.ProcessCustody.set_signal_hook(control, fn
      :process, ^child_pid, _signal -> {:error, :eperm}
      _target_type, _target, _signal -> :continue
    end)

    assert_receive {:descendant_monitor_stopped, _root_pid}, 2_000
    assert {:error, reason} = Task.await(run_task, 6_000)
    assert reason =~ "process cleanup failed"
    assert alive?(child_pid)

    assert {:ok, %{"groups" => [%{"descendants" => descendants}]}} =
             Kogen.ProcessCustody.read_lock(control)

    assert Enum.any?(descendants, &(&1["pid"] == child_pid))

    Kogen.ProcessCustody.clear_signal_hook(control)
    assert :ok = Kogen.ProcessCustody.release(control)
    refute alive?(child_pid)
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

  test "a stale lock cannot signal a different live process group", %{base: base} do
    control = control_dir(base)
    out = out_dir(base)

    unrelated_task =
      Task.async(fn -> Kogen.ProcessCustody.run([@provider_script, out], System.tmp_dir!()) end)

    unrelated_pid = wait_for_pid_file(out, "provider.pid")
    child_pid = wait_for_pid_file(out, "grandchild.pid")
    assert unrelated_pid && child_pid
    leader = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["30"]])
    {:os_pid, leader_pid} = Port.info(leader, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", "-#{unrelated_pid}"], stderr_to_stdout: true)
      System.cmd("/bin/kill", ["-9", to_string(leader_pid)], stderr_to_stdout: true)
    end)

    stale_lock = %{
      "pid" => 999_999,
      "started_at" => "Thu Jan  1 00:00:00 1970",
      "build_id" => "stale-build",
      "groups" => [
        %{
          "pid" => leader_pid,
          "pgid" => unrelated_pid,
          "started_at" => Kogen.ProcessCustody.process_start(leader_pid),
          "role" => "developer"
        }
      ]
    }

    File.write!(Kogen.ProcessCustody.lock_path(control), Jason.encode!(stale_lock))

    assert {:error, reason} = Kogen.ProcessCustody.acquire(control)
    assert reason =~ "recorded process group does not match its leader"
    assert alive?(leader_pid)
    assert alive?(unrelated_pid)
    assert alive?(child_pid)

    another = control_dir(base)
    assert {:ok, :fresh} = Kogen.ProcessCustody.acquire(another)

    assert {:error, :invalid_group_identity} =
             Kogen.ProcessCustody.record_group(another, "developer", %{
               "pid" => leader_pid,
               "pgid" => unrelated_pid,
               "started_at" => Kogen.ProcessCustody.process_start(leader_pid)
             })

    assert {:ok, %{"groups" => []}} = Kogen.ProcessCustody.read_lock(another)

    System.cmd("/bin/kill", ["-KILL", "-#{unrelated_pid}"], stderr_to_stdout: true)
    Task.yield(unrelated_task, 1_000) || Task.shutdown(unrelated_task, :brutal_kill)
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
          # `mix run` needs the project's mix.exs, so the stand-in must start
          # from the checkout root rather than inherit the shared VM's mutable
          # cwd (another async module may have `File.cd!`-ed away from it).
          cd: System.fetch_env!("KOGEN_TEST_ROOT"),
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
        cd: System.fetch_env!("KOGEN_TEST_ROOT"),
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

  # -- process-and-capacity: outer-fixture death ------------------------------
  #
  # A canceled outer live-test process can leave a *nested* fixture controller
  # alive (background: a nested `mix kogen.build` launched by a live fixture,
  # itself launching its own Developer through `Kogen.ProcessCustody.run/3`).
  # This drives that exact three-level tree through the real production
  # pieces: an "outer" OS process (standing in for the live-test driver)
  # launches the real supervisor directly (as the earlier "parent-death
  # watchdog" test does) around a *nested controller* (the real
  # `custody_controller_standin.exs`, in "hang" mode), which in turn launches
  # the fake provider (and its SIGTERM-ignoring grandchild) through its own,
  # separate `Kogen.ProcessCustody.run/3` and lock. Killing only the outer
  # process, with no Elixir cleanup code anywhere in the chain, must still
  # reap every descendant: the nested controller's own parent-death watchdog
  # reaps it when the outer dies, and the provider's watchdog then reaps it in
  # turn once the nested controller (its own controller_pid) is gone -- while
  # an unrelated process group is left alive throughout.

  defp start_unrelated_group do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    %{port: port, pid: pid}
  end

  test "an outer process's kill -9 reaps a nested fixture controller and its own child, leaving an unrelated group alive",
       %{base: base} do
    out = out_dir(base)
    nested_control = control_dir(base)
    unrelated = start_unrelated_group()

    on_exit(fn ->
      System.cmd("/bin/kill", ["-9", to_string(unrelated.pid)], stderr_to_stdout: true)
    end)

    # The "outer" process: stands in for a canceled live-test driver. It runs
    # no Kogen code at all; it is simply the process whose death the nested
    # controller's own supervisor must notice.
    outer_port = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["60"]])
    {:os_pid, outer_pid} = Port.info(outer_port, :os_pid)

    log = Path.join(out, "nested-controller-log")

    spec = %{
      "argv" => [
        mix_executable(),
        "run",
        Path.expand("../support/custody_controller_standin.exs", __DIR__),
        "hang",
        nested_control,
        out
      ],
      "cwd" => System.fetch_env!("KOGEN_TEST_ROOT"),
      "log" => log,
      "mode" => "batch",
      "stdin_path" => nil,
      "tmp_dir" => nil,
      "timeout" => nil,
      "grace" => 0.5,
      "poll" => 0.1,
      "controller_pid" => outer_pid,
      "register_path" => nil
    }

    python3 = System.find_executable("python3") |> to_charlist()

    supervisor_port =
      Port.open({:spawn_executable, python3}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [Kogen.ProcessCustody.supervisor_script_path(), Jason.encode!(spec)],
        env: [{~c"FAKE_PROVIDER", String.to_charlist(@provider_script)}]
      ])

    provider_pid = wait_for_pid_file(out, "provider.pid", 10_000)
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid", 10_000)
    assert provider_pid && grandchild_pid

    assert wait_until(fn ->
             match?(
               {:ok, %{"groups" => [_ | _]}},
               Kogen.ProcessCustody.read_lock(nested_control)
             )
           end)

    # The nested controller is the real `custody_controller_standin.exs`
    # "hang" process, identified by the top-level pid it recorded on its own
    # `acquire/1` -- never the supervisor script (S1) that launched it.
    {:ok, %{"pid" => nested_controller_pid}} = Kogen.ProcessCustody.read_lock(nested_control)
    assert alive?(nested_controller_pid)

    # Simulate `kill -9` of the outer live-test driver: nothing downstream
    # ever runs any Elixir (or Python) cleanup code in response.
    System.cmd("/bin/kill", ["-9", to_string(outer_pid)], stderr_to_stdout: true)

    # The nested controller's own watchdog reaps it once its parent (the
    # outer process) is gone; then the provider's own watchdog reaps it and
    # its grandchild once the nested controller (its controller_pid) is gone.
    assert wait_until(fn -> !alive?(nested_controller_pid) end, 8_000)
    assert wait_until(fn -> !alive?(provider_pid) end, 8_000)
    assert wait_until(fn -> !alive?(grandchild_pid) end, 8_000)
    refute alive?(nested_controller_pid)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    assert alive?(unrelated.pid)

    receive do
      {^supervisor_port, {:exit_status, _}} -> :ok
    after
      2_000 -> :ok
    end
  end
end
