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

    {output, status} = System.cmd("python3", ["-B", rehearsal], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "Ran "
    assert output =~ "OK"
  end
end
