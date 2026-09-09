defmodule Kogen.IsolationCleanupTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/isolation_probe.exs", __DIR__)

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
               collection_timeout: 2_000,
               env: [{"PROBE_PID", marker}]
             )

    pid = File.read!(marker) |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "collection returned before subprocess termination"
    assert output =~ "isolated children terminated; private fixture still present"
    refute File.exists?(File.read!(marker <> ".root"))
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
end
