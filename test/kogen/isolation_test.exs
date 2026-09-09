defmodule Kogen.IsolationTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/isolation_probe.exs", __DIR__)

  test "independent children overlap and isolate cwd, environment, and temporary roots" do
    root = tmp_dir!()
    original_cwd = File.cwd!()
    original_env = System.get_env("PROBE_LOCAL")

    tasks =
      for {name, peer} <- [{"a", "b"}, {"b", "a"}] do
        Task.async(fn ->
          Kogen.IsolatedCase.run(@probe, "test overlap",
            parameters: %{test: :"test overlap"},
            env: [{"PROBE_ROOT", root}, {"PROBE_NAME", name}, {"PROBE_PEER", peer}]
          )
        end)
      end

    for task <- tasks, do: assert({:ok, _} = Task.await(task, 10_000))
    assert File.cwd!() == original_cwd
    assert System.get_env("PROBE_LOCAL") == original_env
    assert File.read!(Path.join(root, "a.count")) == "once\n"
    assert File.read!(Path.join(root, "b.count")) == "once\n"
    a_tmp = File.read!(Path.join(root, "a.tmp"))
    b_tmp = File.read!(Path.join(root, "b.tmp"))
    assert a_tmp != b_tmp
    refute File.exists?(a_tmp)
    refute File.exists?(b_tmp)
  end

  test "assertions and nonzero child exits propagate with diagnostics" do
    marker = Path.join(tmp_dir!(), "failure-child.pid")

    assert {:error, {:exit_status, 1}, output} =
             Kogen.IsolatedCase.run(@probe, "test nonexistent")

    assert output =~ "expected exactly one passing isolated test"

    assert {:error, {:exit_status, 1}, output} =
             Kogen.IsolatedCase.run(@probe, "test assertion failure",
               env: [{"PROBE_PID", marker}]
             )

    assert output =~ "intentional isolated assertion"
    pid = marker |> File.read!() |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "failed test subprocess #{pid} survived cleanup"

    assert {:error, {:exit_status, 23}, output} =
             Kogen.IsolatedCase.run(@probe, "test nonzero exit",
               env: [{"PROBE_PID", marker <> ".abrupt"}]
             )

    assert output =~ "intentional isolated exit"
    abrupt_pid = File.read!(marker <> ".abrupt") |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", abrupt_pid], stderr_to_stdout: true)
    assert status != 0, "abruptly halted VM left subprocess #{abrupt_pid} alive"
  end

  test "timeouts propagate and parent cancellation reaps a running subprocess" do
    marker = Path.join(tmp_dir!(), "child.pid")

    assert {:error, :timeout, _} =
             Kogen.IsolatedCase.run(@probe, "test timeout with child",
               timeout: 1,
               env: [{"PROBE_PID", marker}]
             )

    # Wait for evidence of a running subprocess before cancelling its owner.
    # This separates the cleanup assertion from variable VM startup latency.
    owner =
      spawn(fn ->
        Kogen.IsolatedCase.run(@probe, "test timeout with child", env: [{"PROBE_PID", marker}])
      end)

    monitor = Process.monitor(owner)

    assert Enum.any?(1..500, fn _ ->
             if File.exists?(marker),
               do: true,
               else:
                 (
                   Process.sleep(10)
                   false
                 )
           end)

    pid = marker |> File.read!() |> String.trim()
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert Enum.any?(1..100, fn _ ->
             {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)

             if status != 0,
               do: true,
               else:
                 (
                   Process.sleep(10)
                   false
                 )
           end),
           "cancelled subprocess #{pid} survived cleanup"
  end

  test "every maintained test module explicitly enables async execution" do
    for source <- Path.wildcard(Path.expand("*_test.exs", __DIR__)) do
      text = File.read!(source)

      assert Regex.match?(~r/use (?:ExUnit.Case|Kogen.IsolatedCase),\s*async: true/, text),
             "#{source} must explicitly use async: true"
    end
  end

  test "the offline provider denial shim fails closed and leaves a receipt" do
    fixture = tmp_dir!()
    shim = Path.expand("../support/codex", __DIR__)
    assert {_, 1} = System.cmd(shim, ["unexpected-provider-launch"], cd: fixture)
    receipt = File.read!(Path.join(fixture, ".kogen/runtime/path-shim-invoked"))
    assert receipt =~ "PATH-SHIM-CODEX-INVOKED: unexpected-provider-launch"
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
end
