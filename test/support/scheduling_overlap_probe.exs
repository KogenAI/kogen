# Loaded explicitly by the scheduling regression, not by the ordinary test glob.
# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
defmodule Kogen.SchedulingOverlapProbe do
  def run(id) do
    root = System.fetch_env!("SCHEDULING_RENDEZVOUS")
    File.write!(Path.join(root, "#{id}.ready"), "ready\n")
    await_peer!(root, id, System.monotonic_time(:millisecond) + 5_000)
    File.write!(Path.join(root, "#{id}.steps"), "started\ndependent-finished\n")

    if System.get_env("SCHEDULING_FAIL") == Atom.to_string(id) do
      raise "requested #{id} owner failure"
    end
  end

  defp await_peer!(root, id, deadline) do
    peer = if id == :connected, do: :rework, else: :connected

    cond do
      File.exists?(Path.join(root, "#{peer}.ready")) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "independent owners serialized"

      true ->
        Process.sleep(10)
        await_peer!(root, id, deadline)
    end
  end
end

defmodule Kogen.SchedulingConnectedProbeTest do
  use Kogen.IsolatedCase, async: true

  @tag env: [
         {"SCHEDULING_RENDEZVOUS", System.fetch_env!("SCHEDULING_RENDEZVOUS")},
         {"SCHEDULING_FAIL", System.get_env("SCHEDULING_FAIL", "")}
       ]
  test "connected owner rendezvous", do: Kogen.SchedulingOverlapProbe.run(:connected)
end

defmodule Kogen.SchedulingReworkProbeTest do
  use Kogen.IsolatedCase, async: true

  @tag env: [
         {"SCHEDULING_RENDEZVOUS", System.fetch_env!("SCHEDULING_RENDEZVOUS")},
         {"SCHEDULING_FAIL", System.get_env("SCHEDULING_FAIL", "")}
       ]
  test "rework owner rendezvous", do: Kogen.SchedulingOverlapProbe.run(:rework)
end
