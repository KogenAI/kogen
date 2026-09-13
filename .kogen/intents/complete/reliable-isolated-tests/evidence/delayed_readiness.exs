defmodule Kogen.ShapingDelayedReadinessProbe do
  use Kogen.IsolatedCase, async: true
  test "delayed startup" do
    Process.sleep(3_000)
    File.write!(System.fetch_env!("SHAPING_READY_MARKER"), "ready")
    Process.sleep(10_000)
  end
end
