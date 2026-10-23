Code.require_file("../support/integration_helpers.ex", __DIR__)

defmodule Kogen.Integration.HelpersTest do
  use ExUnit.Case, async: true
  alias Kogen.Integration.{Custodian, FakeProvider, Helpers}

  @moduletag timeout: 300_000

  test "marker readiness exceeds the former deadline and missing markers name their path" do
    root = temporary!()
    on_exit(fn -> File.rm_rf!(root) end)
    marker = Path.join(root, "ready")

    task =
      Task.async(fn ->
        Process.sleep(11_000)
        File.write!(marker, "ready")
      end)

    assert :ok = Helpers.wait_for_file!(marker)
    Task.await(task)
    missing = Path.join(root, "absent")

    assert_raise RuntimeError, "timed out waiting for #{missing}", fn ->
      Helpers.wait_for_file!(missing, 50)
    end
  end

  for reason <- [:shutdown, :kill] do
    @reason reason
    test "cleanup retains custody after owner #{@reason}" do
      root = temporary!()
      child_file = Path.join(root, "child")
      parent = self()
      reason = @reason

      {owner, monitor} =
        spawn_monitor(fn ->
          {:ok, ports} = Custodian.start()
          server = FakeProvider.start([])
          context = %{ports: ports, server: server, root: root}

          command =
            "trap 'kill $child; wait; exit 0' TERM; sleep 600 & child=$!; echo $child > #{child_file}; wait"

          port =
            GenServer.call(
              ports,
              {:open, "/bin/sh",
               [:binary, :exit_status, {:args, [~c"-c", String.to_charlist(command)]}], self()}
            )

          {:os_pid, cli} = Port.info(port, :os_pid)
          Helpers.wait_for_file!(child_file)
          child = child_file |> File.read!() |> String.trim()
          send(parent, {:fixture, context, cli, child})

          receive do
            :shutdown -> exit(:shutdown)
          end
        end)

      assert_receive {:fixture, context, cli, child}, 60_000

      unrelated =
        Port.open({:spawn_executable, ~c"/bin/sleep"}, [:exit_status, {:args, [~c"600"]}])

      {:os_pid, other} = Port.info(unrelated, :os_pid)

      on_exit(fn ->
        System.cmd("/bin/kill", ["-KILL", to_string(other)], stderr_to_stdout: true)
      end)

      shutdown(owner, reason)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 60_000
      Helpers.cleanup_case(context)
      refute File.exists?(root)
      refute alive?(cli)
      refute alive?(child)
      assert alive?(other)
    end
  end

  test "already completed invocations clean up harmlessly" do
    root = temporary!()
    {:ok, ports} = Custodian.start()
    context = %{ports: ports, server: FakeProvider.start([]), root: root}

    port =
      GenServer.call(
        ports,
        {:open, "/bin/sh", [:binary, :exit_status, {:args, [~c"-c", ~c"exit 0"]}], self()}
      )

    assert {"", 0} = Helpers.await_exit(port)
    Helpers.cleanup_case(context)
    refute File.exists?(root)
  end

  test "a failed invocation reaps descendants even when its parent has already exited" do
    root = temporary!()
    child_file = Path.join(root, "child")
    {:ok, ports} = Custodian.start()
    context = %{ports: ports, server: FakeProvider.start([]), root: root}
    command = "sleep 600 & echo $! > #{Kogen.Init.shell_quote(child_file)}; echo failed; exit 196"

    port =
      GenServer.call(
        ports,
        {:open, "/bin/sh",
         [:binary, :exit_status, {:args, [~c"-c", String.to_charlist(command)]}], self()}
      )

    assert {"failed\n", 196} = Helpers.await_exit(port)
    child = child_file |> File.read!() |> String.trim()
    refute alive?(child)
    Helpers.cleanup_case(context)
    refute File.exists?(root)
  end

  for outcome <- [:failed, :owner_killed] do
    @outcome outcome
    test "project preparation #{@outcome} stops descendants before removing its workspace" do
      preparation_case(@outcome)
    end
  end

  defp preparation_case(outcome) do
    root = temporary!()
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.join(root, "preparing-kogen")
    used_repo = Path.join(root, "used-repo")
    child_file = Path.join(root, "child")
    tail = if outcome == :failed, do: "echo 'preparation failed'; exit 196", else: "wait"

    File.write!(
      executable,
      "#!/bin/sh\npwd > #{Kogen.Init.shell_quote(used_repo)}\nsleep 600 & echo $! > #{Kogen.Init.shell_quote(child_file)}\n#{tail}\n"
    )

    File.chmod!(executable, 0o755)
    suite = %{release: executable, path: System.get_env("PATH")}

    if outcome == :failed do
      assert_raise RuntimeError, ~r/kogen init failed: preparation failed/, fn ->
        Helpers.project!(suite, [])
      end
    else
      {owner, ref} = spawn_monitor(fn -> Helpers.project!(suite, []) end)
      Helpers.wait_for_file!(child_file)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 60_000
    end

    case_root = used_repo |> File.read!() |> String.trim() |> Path.dirname()
    child = child_file |> File.read!() |> String.trim()
    wait_removed!(case_root, System.monotonic_time(:millisecond) + 30_000)
    refute File.exists?(case_root)
    refute alive?(child)
  end

  test "a startup error does not destroy custody of an already running invocation" do
    root = temporary!()
    {:ok, ports} = Custodian.start()
    context = %{ports: ports, server: FakeProvider.start([]), root: root}

    port =
      GenServer.call(
        ports,
        {:open, "/bin/sleep", [:binary, :exit_status, {:args, [~c"600"]}], self()}
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    assert {:error, _} =
             GenServer.call(
               ports,
               {:open, Path.join(root, "missing"), [:binary, :exit_status], self()}
             )

    Helpers.cleanup_case(context)
    refute alive?(pid)
    refute File.exists?(root)
  end

  defp wait_removed!(root, deadline) do
    if File.exists?(root) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      wait_removed!(root, deadline)
    end
  end

  defp shutdown(owner, :kill), do: Process.exit(owner, :kill)
  defp shutdown(owner, :shutdown), do: send(owner, :shutdown)

  defp alive?(pid) do
    {_, status} = System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp temporary! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-helper-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    path
  end
end
