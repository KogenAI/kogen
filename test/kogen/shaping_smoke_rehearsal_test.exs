defmodule Kogen.ShapingSmokeRehearsalTest do
  @moduledoc """
  Offline rehearsal for the standalone smoke case (driver.py --smoke): runs
  the same smoke path with the fake transport, asserting mechanics on the
  passing path and two wrong controls (a missing scripted answer that must
  fire fail-fast, and an invalid smoke manifest that must be rejected).
  """
  use Kogen.IsolatedCase, async: true

  @support Path.expand("../support/shaping_evaluation", __DIR__)

  test "offline smoke rehearsal dispatches real driver/integrity functions and manifests once" do
    rehearsal = Path.join(@support, "driver_smoke_rehearsal_test.py")

    {output, status} =
      System.cmd("python3", ["-B", rehearsal],
        stderr_to_stdout: true,
        env: python_env()
      )

    assert status == 0, output
    assert output =~ "Ran "
    assert output =~ "OK"
  end

  test "K5 the smoke Python runners drop a Build session's KOGEN_ROLE and KOGEN_HARNESS_HOME" do
    previous = %{
      "KOGEN_ROLE" => System.get_env("KOGEN_ROLE"),
      "KOGEN_HARNESS_HOME" => System.get_env("KOGEN_HARNESS_HOME")
    }

    on_exit(fn ->
      for {name, nil} <- previous, do: System.delete_env(name)
      for {name, value} when is_binary(value) <- previous, do: System.put_env(name, value)
    end)

    System.put_env("KOGEN_ROLE", "developer")
    System.put_env("KOGEN_HARNESS_HOME", "/tmp/kogen-hostile-home")

    {output, 0} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          "import os; print(os.environ.get('KOGEN_ROLE'), os.environ.get('KOGEN_HARNESS_HOME'))"
        ],
        env: python_env()
      )

    assert output == "None None\n"
  end

  defp python_env, do: [{"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}]
end
