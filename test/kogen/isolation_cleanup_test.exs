defmodule Kogen.IsolationCleanupTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)
  alias Kogen.IsolatedCase.Pool

  @probe Path.expand("../support/isolation_probe.exs", __DIR__)
  @pool_probe Path.expand("../support/warm_pool_probe.exs", __DIR__)

  test "a demanded isolated test passes a queued speculative test under one global permit" do
    root = tmp_dir!()
    log = Path.join(root, "order.log")
    {:ok, server} = Pool.start_test_server(1)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    options = [env: [{"POOL_LOG", log}]]

    first = Pool.register([{"test slow", @pool_probe, options}], server)

    assert eventually?(fn -> File.exists?(log) end)

    queued =
      Pool.register([{"test queued", @pool_probe, options}], server)

    demanded =
      Pool.register([{"test demanded", @pool_probe, options}], server)

    assert {:ok, _output} = Pool.await(demanded, "test demanded", 10_000)
    assert :ok = Pool.cancel(first)
    assert :ok = Pool.cancel(queued)
    assert :ok = Pool.cancel(demanded)

    lines = File.read!(log) |> String.split("\n", trim: true)

    assert "demanded:done" in lines

    if "queued:start" in lines do
      assert Enum.find_index(lines, &(&1 == "demanded:done")) <
               Enum.find_index(lines, &(&1 == "queued:start"))
    end
  end

  test "worker death reports failure and releases the permit without losing the next job" do
    root = tmp_dir!()
    marker = Path.join(root, "child.pid")
    ready = Path.join(root, "ready")
    log = Path.join(root, "order.log")
    {:ok, server} = Pool.start_test_server(1)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    failed =
      Pool.register(
        [
          {"test timeout with child", @probe,
           env: [{"PROBE_PID", marker}, {"PROBE_READY", ready}]}
        ],
        server
      )

    next =
      Pool.register(
        [{"test demanded", @pool_probe, env: [{"POOL_LOG", log}]}],
        server
      )

    assert eventually?(fn -> File.exists?(marker) end)
    pid = File.read!(marker) |> String.trim()
    [{_key, %{pid: worker}}] = :sys.get_state(server).running |> Enum.to_list()
    Process.exit(worker, :kill)

    assert {:error, {:pool_worker_exit, :killed}, ""} =
             Pool.await(failed, "test timeout with child", 5_000)

    assert {:ok, _output} = Pool.await(next, "test demanded", 10_000)
    assert :ok = Pool.cancel(failed)
    assert :ok = Pool.cancel(next)
    assert File.read!(log) == "demanded:start\ndemanded:done\n"

    assert eventually?(fn ->
             {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
             status != 0
           end)

    refute File.exists?(File.read!(marker <> ".root"))
  end

  test "cancelled pool work confirms child process cleanup before returning" do
    root = tmp_dir!()
    marker = Path.join(root, "child.pid")
    ready = Path.join(root, "ready")
    {:ok, server} = Pool.start_test_server(1)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    pool =
      Pool.register(
        [
          {"test timeout with child", @probe,
           env: [{"PROBE_PID", marker}, {"PROBE_READY", ready}]}
        ],
        server
      )

    assert eventually?(fn -> File.exists?(marker) end)
    pid = File.read!(marker) |> String.trim()
    assert :ok = Pool.cancel(pool)
    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
    refute File.exists?(File.read!(marker <> ".root"))
  end

  test "a passing child cannot hide a private-directory deletion failure" do
    marker = Path.join(tmp_dir!(), "cleanup-root")

    on_exit(fn ->
      if File.exists?(marker) do
        root = File.read!(marker)
        File.chmod(Path.join(root, "undeletable"), 0o700)
        File.rm_rf!(root)
      end
    end)

    assert {:error, {:exit_status, 1}, output} =
             Kogen.IsolatedCase.run(@probe, "test passing test with undeletable directory",
               env: [{"PROBE_ROOT_MARKER", marker}]
             )

    assert output =~ "Result: 1 passed"
    assert output =~ "could not remove private fixture"
    assert output =~ "Permission denied"
    root = File.read!(marker)
    assert File.dir?(root)

    assert File.read!(Path.join(root, "undeletable/retained.txt")) ==
             "cleanup must report failure\n"
  end

  test "collection timeout awaits supervisor cleanup before removing its temporary root" do
    marker = Path.join(tmp_dir!(), "collection-child.pid")

    assert {:error, :timeout, output} =
             Kogen.IsolatedCase.run(@probe, "test timeout with child",
               readiness: "PROBE_READY",
               startup_timeout: 10_000,
               collection_timeout: 2_000,
               env: [{"PROBE_PID", marker}, {"PROBE_START_DELAY_MS", "3500"}]
             )

    pid = File.read!(marker) |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "collection returned before subprocess termination"
    assert output =~ "isolated children terminated; private fixture still present"
    refute File.exists?(File.read!(marker <> ".root"))
  end

  test "concurrent isolated timeouts settle their owned children" do
    root = tmp_dir!()

    tasks =
      for name <- ~w(first second) do
        marker = Path.join(root, "#{name}.pid")

        Task.async(fn ->
          result =
            Kogen.IsolatedCase.run(@probe, "test timeout with child",
              readiness: "PROBE_READY",
              startup_timeout: 15_000,
              timeout: 200,
              collection_timeout: 5_000,
              env: [{"PROBE_PID", marker}]
            )

          {marker, result}
        end)
      end

    for task <- tasks do
      {marker, result} = Task.await(task, 20_000)
      assert {:error, :timeout, output} = result
      assert output =~ "isolated children terminated"
      pid = marker |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0, "concurrent timeout left child #{pid} alive"
      refute File.exists?(File.read!(marker <> ".root"))
    end
  end

  test "a denied group signal cannot cause an unbounded launcher wait or claim cleanup" do
    root = Path.expand("../..", __DIR__)

    probe = ~S'''
    import importlib.util, json, pathlib, subprocess, sys
    spec = importlib.util.spec_from_file_location("isolation", sys.argv[1])
    isolation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(isolation)

    waits = []
    class Child:
        pid = 123456789
        returncode = None
        def wait(self, timeout=None):
            waits.append(timeout)
            if timeout is None:
                raise AssertionError("unbounded wait")
            raise subprocess.TimeoutExpired(["fake-child"], timeout)

    class Observer:
        def wait(self, timeout):
            waits.append(timeout)
            return False

    def denied(_pid, _signal):
        raise PermissionError("signal denied")

    isolation.os.killpg = denied
    isolation.os.kill = lambda pid, sig: None
    isolation.os.getpgid = lambda pid: pid
    try:
        isolation.settle_group(Child(), Observer())
    except RuntimeError as error:
        print(json.dumps({"waits":waits, "error":str(error)}))
    else:
        raise AssertionError("denied signal was reported as cleanup success")
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", probe, Path.join(root, "test/support/isolated_process.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.trim() |> Jason.decode!()
    assert result["waits"] == [0.2, 1]
    assert result["error"] =~ "survived bounded group cleanup"
  end

  test "a reaped isolated leader never signals a reused process group" do
    root = Path.expand("../..", __DIR__)

    probe = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("isolation", sys.argv[1])
    isolation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(isolation)

    class ReapedChild:
        pid = 123456789
        returncode = 0
        def wait(self, timeout=None):
            return 0

    class Observer:
        def wait(self, timeout):
            return True

    signalled = []
    isolation.os.killpg = lambda pid, sig: signalled.append([pid, sig])
    isolation.wait_group = lambda pid: None
    isolation.settle_group(ReapedChild(), Observer())
    print(json.dumps(signalled))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          probe,
          Path.join(root, "test/support/isolated_process.py")
        ],
        cd: @project_root
      )

    assert Jason.decode!(String.trim(output)) == []
  end

  test "an isolated child emits one selected suite result" do
    marker = Path.join(tmp_dir!(), "ready")

    assert {:ok, output} =
             Kogen.IsolatedCase.run(@probe, "test delayed readiness",
               env: [{"PROBE_READY", marker}, {"PROBE_DELAY_MS", "0"}]
             )

    assert length(String.split(output, "Result: 1 passed")) == 2
    refute output =~ "Result: 0 tests"
  end

  test "never-ready cleanup fails distinctly without assuming descendant markers exist" do
    marker = Path.join(tmp_dir!(), "never-created-child.pid")

    assert {:error, :readiness_timeout, output} =
             Kogen.IsolatedCase.run(@probe, "test missing readiness",
               readiness: "PROBE_READY",
               startup_timeout: 100,
               collection_timeout: 2_000,
               env: [{"PROBE_PID", marker}]
             )

    assert output =~ "isolated children terminated"
    refute File.exists?(marker)
    refute File.exists?(marker <> ".root")
  end

  test "prelaunch setup failures remove the unowned private directory" do
    root = tmp_dir!()

    assert_raise ArithmeticError, fn ->
      Kogen.IsolatedCase.run(@probe, "test overlap",
        timeout: "not-a-number",
        tmpdir_root: root
      )
    end

    assert File.ls!(root) == []
  end

  test "launcher failure before supervisor startup removes the unowned directory" do
    root = tmp_dir!()

    assert {:error, {:exit_status, status}, _output} =
             Kogen.IsolatedCase.run(@probe, "test overlap",
               cd: Path.join(root, "missing-working-dir"),
               tmpdir_root: root
             )

    assert status != 0
    assert File.ls!(root) == []
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-isolation-probe-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp eventually?(condition) do
    Enum.any?(1..500, fn _ ->
      if condition.() do
        true
      else
        Process.sleep(10)
        false
      end
    end)
  end
end
