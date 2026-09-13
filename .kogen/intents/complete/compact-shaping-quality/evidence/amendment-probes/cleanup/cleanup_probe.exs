# Evidence-local probe for the existing Kogen.IsolatedCase cleanup contract.
# This file is intentionally outside test discovery and is not a production fix.
defmodule CleanupAmendmentProbe do
  use Kogen.IsolatedCase, async: true

  test "delayed marker without readiness" do
    Process.sleep(String.to_integer(System.fetch_env!("PROBE_DELAY_MS")))
    File.write!(System.fetch_env!("PROBE_MARKER"), "marker\n")
    Process.sleep(60_000)
  end

  test "delayed marker with readiness" do
    Process.sleep(String.to_integer(System.fetch_env!("PROBE_DELAY_MS")))
    File.write!(System.fetch_env!("PROBE_MARKER"), "marker\n")
    File.write!(System.fetch_env!("PROBE_READY"), "ready\n")
    Process.sleep(60_000)
  end
end
