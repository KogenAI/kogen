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
  @standin_ready_timeout_ms 10_000
  @standin_cleanup_timeout_ms 5_000

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "kogen-custody-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    on_exit(fn ->
      cleanup_fixture_standins!(base)
      File.rm_rf(base)
    end)

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

  test "a lock update is never observable as an empty or partial lock", %{base: base} do
    # A holder killed mid-update (a crashed Shaping runner recording an audit
    # group) must leave a readable lock; an empty one blocks reclaim for the
    # whole unreadable-lock grace period.
    control = control_dir(base)
    {:ok, :fresh} = Kogen.ProcessCustody.acquire(control)
    on_exit(fn -> Kogen.ProcessCustody.release(control) end)
    path = Kogen.ProcessCustody.lock_path(control)
    {:ok, identity} = Kogen.ProcessCustody.read_lock(control)
    identity = Map.take(identity, ["pid", "started_at", "groups"])
    padding = String.duplicate("x", 64 * 1024)
    parent = self()

    reader =
      spawn_link(fn ->
        read_until_stopped = fn read_until_stopped, partial ->
          partial =
            case File.read(path) do
              {:ok, bytes} ->
                case Jason.decode(bytes) do
                  {:ok, record} when is_map(record) ->
                    if complete_claim?(record, identity, padding),
                      do: partial,
                      else: partial + 1

                  _ ->
                    partial + 1
                end

              {:error, _reason} ->
                partial + 1
            end

          receive do
            :stop -> send(parent, {:partial_reads, partial})
          after
            0 -> read_until_stopped.(read_until_stopped, partial)
          end
        end

        read_until_stopped.(read_until_stopped, 0)
      end)

    for index <- 1..300,
        do: :ok = Kogen.ProcessCustody.claim(control, "build-#{index}-#{padding}")

    send(reader, :stop)
    assert_receive {:partial_reads, 0}, 5_000
    assert {:ok, %{"build_id" => "build-300-" <> _}} = Kogen.ProcessCustody.read_lock(control)

    # The old truncate/write algorithm fails the same reader invariant while
    # its writer is paused after truncation. This is a deterministic control,
    # rather than relying on the scheduler to expose a short empty-file gap.
    original = File.read!(path)

    writer =
      Task.async(fn ->
        {:ok, io} = File.open(path, [:read, :write])
        :ok = :file.truncate(io)
        send(parent, :truncated)

        receive do
          :finish -> :ok
        end

        :ok = IO.binwrite(io, original)
        File.close(io)
      end)

    assert_receive :truncated, 5_000
    refute match?({:ok, %{}}, Jason.decode(File.read!(path)))
    send(writer.pid, :finish)
    assert :ok = Task.await(writer)
    assert {:ok, %{"build_id" => "build-300-" <> _}} = Kogen.ProcessCustody.read_lock(control)
    refute complete_claim?(%{}, identity, padding)
    refute complete_claim?(Map.put(identity, "build_id", "build-1-short"), identity, padding)
  end

  defp complete_claim?(record, identity, padding) do
    same_owner? = Map.take(record, ["pid", "started_at", "groups"]) == identity

    valid_claim? =
      case record["build_id"] do
        nil -> Map.has_key?(record, "build_id")
        "build-" <> suffix -> valid_claim_suffix?(suffix, padding)
        _ -> false
      end

    same_owner? and valid_claim?
  end

  defp valid_claim_suffix?(suffix, padding) do
    case String.split(suffix, "-", parts: 2) do
      [index, ^padding] -> valid_claim_index?(Integer.parse(index))
      _ -> false
    end
  end

  defp valid_claim_index?({number, ""}), do: number in 1..300
  defp valid_claim_index?(_), do: false

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
    # already registered sibling group too. The sibling keeps recording new
    # descendants and a lock write replaces the file by rename, so the chmod
    # is injected under the write lock: a concurrent write cannot install a
    # fresh writable lock over it.
    :ok =
      Kogen.ProcessCustody.locked(control, fn ->
        File.chmod(Kogen.ProcessCustody.lock_path(control), 0o444)
      end)

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

  defp start_standin(mode, control, out, ready_timeout_ms \\ @standin_ready_timeout_ms) do
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
    started_at = Kogen.ProcessCustody.process_start(pid)
    standin = %{port: port, pid: pid, started_at: started_at, control: control, out: out}

    # `on_exit/2` runs after a test process exits, including after an assertion
    # failure, in a separate process. Register this immediately after Port.open
    # so a readiness assertion can never strand the controller and its pipe.
    on_exit(fn -> cleanup_standin!(standin) end)

    case wait_for_standin_ready(port, ready_timeout_ms) do
      {:ready, output} ->
        standin
        |> read_standin_owner!()
        |> Map.put(:ready_output, output)

      {:exit_status, status, output} ->
        reason =
          "controller stand-in exited before readiness (status #{status}); output: #{inspect(output)}"

        cleanup_standin!(standin)
        flunk(reason)

      {:timeout, output} ->
        reason =
          "controller stand-in did not report readiness within #{ready_timeout_ms}ms; " <>
            "output: #{inspect(output)}"

        cleanup_standin!(standin)
        flunk(reason)
    end
  end

  defp wait_for_standin_ready(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_standin_ready(port, [], deadline)
  end

  defp collect_standin_ready(port, chunks, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

      if output =~ "READY" do
        {:ready, output}
      else
        receive do
          {^port, {:data, data}} -> collect_standin_ready(port, [data | chunks], deadline)
          {^port, {:exit_status, status}} -> {:exit_status, status, output}
        after
          remaining_ms -> {:timeout, output}
        end
      end
    end
  end

  test "an expired readiness deadline wins over queued READY output" do
    port = make_ref()
    ready_message = {port, {:data, "READY\n"}}
    send(self(), ready_message)

    try do
      deadline = System.monotonic_time(:millisecond) - 1
      assert {:timeout, ""} = collect_standin_ready(port, [], deadline)
      assert_receive ^ready_message, 0
    after
      flush_standin_messages(port)
    end

    assert port_message_count(port) == 0
  end

  test "an expired drain deadline leaves a substantial queued pipe output untouched" do
    port = make_ref()
    messages = for index <- 1..20_000, do: {port, {:data, "chunk-#{index}\n"}}
    Enum.each(messages, &send(self(), &1))

    try do
      deadline = System.monotonic_time(:millisecond) - 1
      assert {:timeout, "prefix"} = drain_standin_until(port, deadline, ["prefix"])
      assert port_message_count(port) == length(messages)
    after
      flush_standin_messages(port)
    end

    assert port_message_count(port) == 0
  end

  test "readiness preserves a coalesced completion chunk before the exit status" do
    port = make_ref()
    completion = {port, {:data, "READY\nSTOPPED\n"}}
    exit_status = {port, {:exit_status, 0}}
    send(self(), completion)
    send(self(), exit_status)

    try do
      assert {:ready, output} = wait_for_standin_ready(port, 1_000)
      assert output == "READY\nSTOPPED\n"
      assert {:ok, 0, ""} = drain_standin(port, 1_000)
    after
      flush_standin_messages(port)
    end

    assert port_message_count(port) == 0
  end

  defp cleanup_standin!(standin) do
    {standin, owner_result} = resolve_standin_owner(standin)
    pid = standin.pid
    started_at = standin.started_at

    results =
      [
        {:owner_identity, owner_result},
        {:controller_stop, cleanup_step(fn -> stop_owned_standin!(pid, started_at) end)},
        {:lock_cleanup, cleanup_step(fn -> clean_standin_lock!(standin) end)},
        {:port_settlement, settle_and_close_standin_port(Map.get(standin, :port))},
        {:provider_processes_stopped,
         cleanup_step(fn -> assert_owned_provider_processes_stopped!(standin.out) end)},
        {:port_closed,
         cleanup_step(fn -> if standin.port, do: assert_standin_port_closed!(standin.port) end)}
      ]

    errors = Enum.filter(results, fn {_name, result} -> match?({:error, _}, result) end)
    probe_result = write_cleanup_probe_artifact(standin, results, errors)
    errors = if probe_result == :ok, do: errors, else: errors ++ [{:probe_artifact, probe_result}]

    case errors do
      [] ->
        IO.puts(:stderr, "CUSTODY_STANDIN_CLEANUP_OK pid=#{pid}")
        :ok

      failures ->
        raise "controller stand-in cleanup had failures: #{format_cleanup_failures(failures)}"
    end
  end

  defp resolve_standin_owner(standin) do
    {fixture_standin_owner(standin), :ok}
  rescue
    error -> {standin, {:error, {:error, Exception.message(error)}}}
  catch
    kind, reason -> {standin, {:error, {kind, inspect(reason)}}}
  end

  defp cleanup_step(fun) do
    fun.()
    :ok
  rescue
    error -> {:error, {:error, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, inspect(reason)}}
  end

  defp settle_and_close_standin_port(nil), do: :ok

  defp settle_and_close_standin_port(port) do
    settle_result = cleanup_step(fn -> settle_standin_port!(port) end)
    close_result = cleanup_step(fn -> close_standin_port!(port) end)

    case {settle_result, close_result} do
      {:ok, :ok} -> :ok
      _ -> {:error, %{settlement: settle_result, close: close_result}}
    end
  end

  defp close_standin_port!(port) do
    case Port.info(port) do
      nil ->
        :ok

      _info ->
        true = Port.close(port)
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp write_cleanup_probe_artifact(standin, results, errors) do
    case System.get_env("KOGEN_CUSTODY_PROBE_ARTIFACT") do
      nil ->
        :ok

      path ->
        write_cleanup_probe_artifact(path, standin, results, errors)
    end
  rescue
    error ->
      {:error, {:error, "could not write cleanup probe artifact: #{Exception.message(error)}"}}
  catch
    kind, reason -> {:error, {kind, "could not write cleanup probe artifact: #{inspect(reason)}"}}
  end

  defp write_cleanup_probe_artifact(path, standin, results, errors) do
    prior = prior_cleanup_probe_artifact(path)
    cleanup = cleanup_probe_results(standin, results, errors)
    inject_failure? = System.get_env("KOGEN_CUSTODY_PROBE_INJECT_CALLBACK_FAILURE") == "1"
    cleanup = Map.put(cleanup, "stage", cleanup_probe_stage())

    artifact =
      prior
      |> Map.put("cleanup", cleanup)
      |> Map.put("injected_callback_failure", inject_failure?)

    with :ok <- File.write(path, Jason.encode!(artifact, pretty: true)) do
      cleanup_probe_write_result(inject_failure?)
    end
  end

  defp prior_cleanup_probe_artifact(path) do
    case File.read(path) do
      {:ok, bytes} -> decode_prior_cleanup_probe_artifact(bytes)
      {:error, :enoent} -> %{}
      {:error, reason} -> %{"prior_artifact_error" => inspect(reason)}
    end
  end

  defp decode_prior_cleanup_probe_artifact(bytes) do
    case Jason.decode(bytes) do
      {:ok, artifact} when is_map(artifact) -> artifact
      other -> %{"prior_artifact_error" => inspect(other)}
    end
  end

  defp cleanup_probe_results(standin, results, errors) do
    %{
      "stage" => "assertion_abort_on_exit_cleanup_complete",
      "controller_stopped" => not same_process?(standin.pid, standin.started_at),
      "lock_absent" => not File.exists?(Kogen.ProcessCustody.lock_path(standin.control)),
      "provider_processes_stopped" => provider_processes_stopped?(standin.out),
      "port_closed" => port_closed?(Map.get(standin, :port)),
      "check_results" =>
        Map.new(results, fn {name, result} -> {Atom.to_string(name), result_json(result)} end),
      "errors" =>
        Enum.map(errors, fn {name, result} ->
          %{"check" => Atom.to_string(name), "result" => result_json(result)}
        end)
    }
  end

  defp cleanup_probe_stage do
    case System.get_env("KOGEN_CUSTODY_PROBE_MODE") do
      "startup" -> "startup_failure_inline_cleanup_complete"
      _ -> "assertion_abort_on_exit_cleanup_complete"
    end
  end

  defp cleanup_probe_write_result(true),
    do: {:error, {:error, "injected callback failure after completed owned-process cleanup"}}

  defp cleanup_probe_write_result(false), do: :ok

  defp provider_processes_stopped?(out) do
    Enum.all?(["provider.pid", "grandchild.pid"], fn name ->
      case File.read(Path.join(out, name)) do
        {:ok, contents} ->
          pid = String.trim(contents) |> String.to_integer()
          not alive?(pid)

        {:error, :enoent} ->
          true

        {:error, _reason} ->
          false
      end
    end)
  rescue
    ArgumentError -> false
  end

  defp port_closed?(nil), do: true

  defp port_closed?(port) do
    Port.info(port) == nil
  rescue
    ArgumentError -> true
  end

  defp result_json(:ok), do: %{"status" => "ok"}
  defp result_json({:error, reason}), do: %{"status" => "error", "reason" => inspect(reason)}

  defp format_cleanup_failures(failures) do
    Enum.map_join(failures, "; ", fn {name, result} ->
      "#{name}=#{inspect(result)}"
    end)
  end

  defp cleanup_fixture_standins!(base) do
    base
    |> Path.join("out-*")
    |> Path.wildcard()
    |> Enum.each(&cleanup_fixture_standin!(&1, base))
  end

  defp cleanup_fixture_standin!(out, base) do
    case File.read(Path.join(out, "standin-owner.json")) do
      {:ok, bytes} ->
        cleanup_fixture_standin_bytes!(bytes, out, base)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "could not read stand-in owner marker in #{out}: #{inspect(reason)}"
    end
  end

  defp cleanup_fixture_standin_bytes!(bytes, out, base) do
    case Jason.decode(bytes) do
      {:ok, %{"pid" => pid, "started_at" => started_at, "control" => control}}
      when is_integer(pid) and is_binary(started_at) ->
        expanded_control = fixture_standin_control!(control, base)

        cleanup_standin!(%{
          pid: pid,
          started_at: started_at,
          control: expanded_control,
          out: out,
          port: nil
        })

      other ->
        raise "invalid stand-in owner marker in #{out}: #{inspect(other)}"
    end
  end

  defp fixture_standin_control!(control, base) do
    expanded_control = Path.expand(control)

    unless Path.dirname(expanded_control) == Path.expand(base) and
             String.starts_with?(Path.basename(expanded_control), "control-") do
      raise "refusing to clean a stand-in outside its private test fixture: #{inspect(control)}"
    end

    expanded_control
  end

  defp read_standin_owner!(standin) do
    owner_path = Path.join(standin.out, "standin-owner.json")

    case File.read(owner_path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{"pid" => pid, "started_at" => started_at}}
          when is_integer(pid) and is_binary(started_at) and started_at != "" ->
            %{standin | pid: pid, started_at: started_at}

          other ->
            flunk("invalid controller stand-in owner marker: #{inspect(other)}")
        end

      {:error, reason} ->
        flunk("controller stand-in did not write its owner marker: #{inspect(reason)}")
    end
  end

  defp fixture_standin_owner(standin) do
    owner_path = Path.join(standin.out, "standin-owner.json")

    case File.read(owner_path) do
      {:ok, bytes} -> fixture_standin_owner_from_bytes(standin, bytes)
      _ -> fixture_standin_lock_owner(standin)
    end
  end

  defp fixture_standin_owner_from_bytes(standin, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"pid" => pid, "started_at" => started_at}}
      when is_integer(pid) and is_binary(started_at) and started_at != "" ->
        %{standin | pid: pid, started_at: started_at}

      _ ->
        standin
    end
  end

  defp fixture_standin_lock_owner(standin) do
    case Kogen.ProcessCustody.read_lock(standin.control) do
      {:ok, %{"pid" => pid, "started_at" => started_at}}
      when is_integer(pid) and is_binary(started_at) and started_at != "" ->
        %{standin | pid: pid, started_at: started_at}

      _ ->
        standin
    end
  end

  defp stop_owned_standin!(pid, started_at) do
    if same_process?(pid, started_at) do
      signal_owned_standin!(pid, started_at, "-TERM")
      stop_owned_standin_after_term!(pid, started_at)
    end
  end

  defp stop_owned_standin_after_term!(pid, started_at) do
    unless wait_until(fn -> !same_process?(pid, started_at) end, @standin_cleanup_timeout_ms) do
      signal_owned_standin!(pid, started_at, "-KILL")
      ensure_owned_standin_stopped!(pid, started_at)
    end
  end

  defp ensure_owned_standin_stopped!(pid, started_at) do
    unless wait_until(fn -> !same_process?(pid, started_at) end, @standin_cleanup_timeout_ms) do
      raise "could not stop owned controller stand-in #{pid} (start #{started_at})"
    end
  end

  defp signal_owned_standin!(pid, started_at, signal) do
    # The Port supplies the PID, and the start-time check prevents a delayed
    # cleanup from signalling an unrelated process after PID reuse.
    if same_process?(pid, started_at) do
      run_owned_standin_signal(pid, started_at, signal)
    end
  end

  defp run_owned_standin_signal(pid, started_at, signal) do
    case System.cmd("/bin/kill", [signal, to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise_owned_standin_signal_failure(pid, started_at, signal, status, output)
    end
  end

  defp raise_owned_standin_signal_failure(pid, started_at, signal, status, output) do
    if same_process?(pid, started_at) do
      raise "could not signal owned controller stand-in #{pid} with #{signal} " <>
              "(status #{status}): #{String.trim(output)}"
    end
  end

  defp same_process?(pid, started_at)
       when is_integer(pid) and is_binary(started_at) and started_at != "" do
    Kogen.ProcessCustody.process_start(pid) == started_at
  end

  defp same_process?(_pid, _started_at), do: false

  defp clean_standin_lock!(%{control: control, pid: pid, started_at: started_at}) do
    case Kogen.ProcessCustody.read_lock(control) do
      {:error, :enoent} ->
        :ok

      {:ok, other} ->
        if fixture_lock_owner?(other, pid, started_at) do
          clean_owned_standin_lock!(control, other)
        else
          raise "refusing to clean a controller lock with different ownership: #{inspect(other)}"
        end

      {:error, reason} ->
        raise "could not read controller lock during cleanup: #{inspect(reason)}"
    end
  end

  defp clean_owned_standin_lock!(control, lock) do
    lock_pid = lock["pid"]
    lock_started_at = lock["started_at"]

    case Kogen.ProcessCustody.teardown(control) do
      {:error, reason} -> raise "could not reap owned controller groups: #{reason}"
      _reaped -> :ok
    end

    case Kogen.ProcessCustody.read_lock(control) do
      {:ok,
       %{
         "pid" => ^lock_pid,
         "started_at" => ^lock_started_at,
         "groups" => []
       }} ->
        case File.rm(Kogen.ProcessCustody.lock_path(control)) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            raise "could not remove owned controller lock: #{inspect(reason)}"
        end

      {:ok,
       %{
         "pid" => ^lock_pid,
         "started_at" => ^lock_started_at,
         "groups" => groups
       }} ->
        raise "owned controller lock retained live groups after cleanup: #{inspect(groups)}"

      other ->
        raise "owned controller lock changed during cleanup: #{inspect(other)}"
    end
  end

  defp fixture_lock_owner?(lock, pid, started_at) do
    actual_owner = {lock["pid"], lock["started_at"]}
    fixture_owner = {pid, started_at}
    current = Kogen.ProcessCustody.self_identity()
    test_owner = {current["pid"], current["started_at"]}

    actual_owner in [fixture_owner, test_owner]
  end

  defp assert_owned_provider_processes_stopped!(out) do
    Enum.each(["provider.pid", "grandchild.pid"], &assert_owned_provider_pid_stopped!(out, &1))
  end

  defp assert_owned_provider_pid_stopped!(out, name) do
    case File.read(Path.join(out, name)) do
      {:ok, contents} ->
        contents |> String.trim() |> String.to_integer() |> assert_provider_pid_stopped!()

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "could not inspect fake provider PID file #{name}: #{inspect(reason)}"
    end
  end

  defp assert_provider_pid_stopped!(pid) do
    if alive?(pid), do: raise("owned fake provider process #{pid} remained after cleanup")
  end

  defp assert_standin_port_closed!(port) do
    case Port.info(port) do
      nil -> :ok
      info -> raise "controller output port remained open after cleanup: #{inspect(info)}"
    end
  rescue
    ArgumentError -> :ok
  end

  defp settle_standin_port!(port) do
    case Port.info(port) do
      nil ->
        :ok

      _info ->
        case drain_standin(port, @standin_cleanup_timeout_ms) do
          {:ok, _status, _output} ->
            :ok

          {:timeout, output} ->
            raise "controller output pipe did not close after cleanup: #{inspect(output)}"
        end
    end
  rescue
    ArgumentError -> :ok
  end

  defp drain_standin(port, budget_ms \\ 5_000) do
    drain_standin_until(port, System.monotonic_time(:millisecond) + budget_ms, [])
  end

  defp drain_standin_until(port, deadline, chunks) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      receive do
        {^port, {:data, data}} ->
          drain_standin_until(port, deadline, [data | chunks])

        {^port, {:exit_status, status}} ->
          output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
          {:ok, status, output}
      after
        remaining_ms ->
          output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
          {:timeout, output}
      end
    end
  end

  defp port_message_count(port) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, &match?({^port, _message}, &1))
  end

  defp flush_standin_messages(port) do
    receive do
      {^port, _message} -> flush_standin_messages(port)
    after
      0 -> :ok
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

      assert {:ok, _status, _output} = drain_standin(standin.port, @standin_cleanup_timeout_ms)
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

    assert {:ok, _status, _output} = drain_standin(standin.port, @standin_cleanup_timeout_ms)
    assert wait_until(fn -> !alive?(standin.pid) end)
    assert wait_until(fn -> !alive?(grandchild_pid) end)
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)

    # The lock is stale (its owner, the killed standin, is dead) but still
    # present; the next Build reclaims it, printing one line naming what it
    # reaped (nothing live, since the watchdog already won the race).
    assert {:ok, {:reclaimed, _reaped}} = Kogen.ProcessCustody.acquire(control)
    assert :ok = Kogen.ProcessCustody.release(control)
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
    assert :ok = Kogen.ProcessCustody.release(control)
  end

  test "a real controller's normal Stop tears its own groups down and releases the lock", %{
    base: base
  } do
    out = out_dir(base)
    control = control_dir(base)

    standin = start_standin("stop", control, out)
    assert standin.ready_output =~ "READY"
    assert {:ok, 0, drained_output} = drain_standin(standin.port)
    output = standin.ready_output <> drained_output
    assert output =~ "READY"
    assert output =~ "STOPPED"

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
    assert standin.ready_output =~ "READY"
    assert {:ok, 0, drained_output} = drain_standin(standin.port)
    output = standin.ready_output <> drained_output
    assert output =~ "READY"
    assert output =~ "TIMED_OUT=true"

    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid
    refute alive?(provider_pid)
    refute alive?(grandchild_pid)
    refute File.exists?(Kogen.ProcessCustody.lock_path(control))
  end

  test "cleanup closes its owned pipe even when the lock ownership check fails", %{base: base} do
    out = out_dir(base)
    control = control_dir(base)
    standin_pid = String.to_integer(System.pid()) + 10_000_000
    standin_started_at = "synthetic-controller-start"
    owner_path = Path.join(out, "standin-owner.json")
    lock_path = Kogen.ProcessCustody.lock_path(control)

    foreign_lock = %{
      "pid" => standin_pid + 1,
      "started_at" => "different-controller-start",
      "groups" => []
    }

    foreign_lock_bytes = Jason.encode!(foreign_lock)

    File.write!(
      owner_path,
      Jason.encode!(%{"pid" => standin_pid, "started_at" => standin_started_at})
    )

    File.write!(lock_path, foreign_lock_bytes)

    port = Port.open({:spawn_executable, "/bin/cat"}, [:exit_status])
    port_pid = Port.info(port)[:os_pid]

    standin = %{
      pid: standin_pid,
      started_at: standin_started_at,
      control: control,
      out: out,
      port: port
    }

    try do
      assert_raise RuntimeError, ~r/lock_cleanup=/, fn -> cleanup_standin!(standin) end
      assert_standin_port_closed!(port)
      assert File.read!(lock_path) == foreign_lock_bytes
      assert wait_until(fn -> not alive?(port_pid) end, 1_000)
    after
      close_standin_port!(port)
      File.rm(owner_path)
      File.rm(lock_path)
    end
  end

  @tag startup_cleanup_probe: true
  test "a failed readiness assertion cleans the owned controller, group, and output pipe", %{
    base: base
  } do
    if System.get_env("KOGEN_CUSTODY_FAILURE_PROBE") == "1" do
      start_standin(
        "unready",
        System.fetch_env!("KOGEN_CUSTODY_CONTROL"),
        System.fetch_env!("KOGEN_CUSTODY_OUT"),
        @standin_ready_timeout_ms
      )
    else
      out = out_dir(base)
      control = control_dir(base)
      {output, status} = run_custody_cleanup_probe("startup", control, out)

      assert status == 0, output
      assert output =~ "did not report readiness"
      assert output =~ "STARTUP_FAILED=readiness was deliberately withheld"
      assert output =~ "CUSTODY_STARTUP_FAILURE_PROBE_PASS"
      assert output =~ "CUSTODY_STANDIN_CLEANUP_OK"
      refute File.exists?(Kogen.ProcessCustody.lock_path(control))
      assert_owned_provider_processes_stopped!(out)

      owner = out |> Path.join("standin-owner.json") |> File.read!() |> Jason.decode!()
      refute same_process?(owner["pid"], owner["started_at"])
    end
  end

  @tag assertion_abort_cleanup_probe: true
  test "an assertion abort with live owned children is settled by on_exit", %{base: base} do
    if System.get_env("KOGEN_CUSTODY_FAILURE_PROBE") == "1" do
      run_assertion_abort_probe_body!()
    else
      out = out_dir(base)
      control = control_dir(base)
      {output, status} = run_custody_cleanup_probe("assertion_abort", control, out)

      assert status == 0, output
      assert output =~ "CUSTODY_ASSERTION_ABORT_PROBE_PASS"
      assert_probe_cleanup_artifact!(out)

      artifact = read_probe_artifact!(out)
      live = artifact["live"]
      refute same_process?(live["controller_pid"], live["controller_started_at"])
      refute alive?(live["provider_pid"])
      refute alive?(live["grandchild_pid"])
      refute File.exists?(Kogen.ProcessCustody.lock_path(control))
    end
  end

  @tag cleanup_callback_failure_probe: true
  test "a cleanup callback failure remains visible after real cleanup", %{base: base} do
    if System.get_env("KOGEN_CUSTODY_FAILURE_PROBE") == "1" do
      run_assertion_abort_probe_body!()
    else
      out = out_dir(base)
      control = control_dir(base)

      {output, status} =
        run_custody_cleanup_probe("assertion_abort_negative_control", control, out)

      assert status != 0, output
      assert output =~ "CUSTODY_ASSERTION_ABORT_PROBE_CALLBACK_FAILURE_CAPTURED"
      assert_probe_cleanup_artifact!(out)

      artifact = read_probe_artifact!(out)
      assert artifact["injected_callback_failure"] == true
      live = artifact["live"]
      refute same_process?(live["controller_pid"], live["controller_started_at"])
      refute alive?(live["provider_pid"])
      refute alive?(live["grandchild_pid"])
      refute File.exists?(Kogen.ProcessCustody.lock_path(control))
    end
  end

  defp run_assertion_abort_probe_body! do
    control = System.fetch_env!("KOGEN_CUSTODY_CONTROL")
    out = System.fetch_env!("KOGEN_CUSTODY_OUT")
    standin = start_standin("hang", control, out)
    provider_pid = wait_for_pid_file(out, "provider.pid")
    grandchild_pid = wait_for_pid_file(out, "grandchild.pid")
    assert provider_pid && grandchild_pid
    assert same_process?(standin.pid, standin.started_at)
    assert alive?(provider_pid)
    assert alive?(grandchild_pid)
    assert Port.info(standin.port)

    {:ok, lock} = Kogen.ProcessCustody.read_lock(control)
    assert lock["pid"] == standin.pid
    assert lock["started_at"] == standin.started_at
    assert lock["groups"] != []

    artifact_path = System.fetch_env!("KOGEN_CUSTODY_PROBE_ARTIFACT")

    live = %{
      "controller_pid" => standin.pid,
      "controller_started_at" => standin.started_at,
      "provider_pid" => provider_pid,
      "grandchild_pid" => grandchild_pid,
      "group_count" => length(lock["groups"]),
      "pipe_open" => true
    }

    File.write!(
      artifact_path,
      Jason.encode!(
        %{
          "probe" => "assertion-abort-owned-process-cleanup",
          "stage" => "live_owned_processes_before_assertion_abort",
          "live" => live
        },
        pretty: true
      )
    )

    assert false,
           "intentional assertion abort after identifying the live controller, provider group, lock, and pipe"
  end

  defp run_custody_cleanup_probe(mode, control, out) do
    probe = Path.expand("../support/custody_standin_startup_failure_probe.exs", __DIR__)

    env =
      if mode == "assertion_abort_negative_control",
        do: [{"KOGEN_CUSTODY_PROBE_INJECT_CALLBACK_FAILURE", "1"}],
        else: []

    System.cmd(mix_executable(), ["run", "--no-compile", probe, mode, control, out],
      cd: System.fetch_env!("KOGEN_TEST_ROOT"),
      stderr_to_stdout: true,
      env: env
    )
  end

  defp read_probe_artifact!(out) do
    out
    |> Path.join("custody-assertion-abort-cleanup-probe.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_probe_cleanup_artifact!(out) do
    artifact = read_probe_artifact!(out)
    assert artifact["probe"] == "assertion-abort-owned-process-cleanup"
    assert artifact["stage"] == "live_owned_processes_before_assertion_abort"
    assert artifact["live"]["pipe_open"] == true
    assert artifact["live"]["group_count"] > 0

    assert %{
             "stage" => "assertion_abort_on_exit_cleanup_complete",
             "controller_stopped" => true,
             "lock_absent" => true,
             "provider_processes_stopped" => true,
             "port_closed" => true,
             "errors" => []
           } = artifact["cleanup"]
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
