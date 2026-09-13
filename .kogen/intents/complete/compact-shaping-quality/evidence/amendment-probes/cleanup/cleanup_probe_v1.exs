# Archived v1 probe source. Retained exactly before the readiness-order correction.
defmodule CleanupAmendmentProbeV1 do
  use Kogen.IsolatedCase, async: true

  test "delayed marker without readiness" do
    Process.sleep(String.to_integer(System.fetch_env!("PROBE_DELAY_MS")))
    File.write!(System.fetch_env!("PROBE_MARKER"), "marker\n")
    Process.sleep(60_000)
  end

  test "delayed marker with readiness" do
    Process.sleep(String.to_integer(System.fetch_env!("PROBE_DELAY_MS")))
    File.write!(System.fetch_env!("PROBE_READY"), "ready\n")
    File.write!(System.fetch_env!("PROBE_MARKER"), "marker\n")
    Process.sleep(60_000)
  end
end
