# Bounded ExUnit scheduling probe; no Kogen gates or providers.
ExUnit.start(autorun: false, max_cases: 2, seed: 0)
{:ok, _} = Agent.start_link(fn -> [] end, name: ProbeEvents)
defmodule ProbeWork do
  def run(id) do
    Agent.update(ProbeEvents, &[{id, :start, System.monotonic_time(:microsecond)} | &1])
    Process.sleep(150)
    Agent.update(ProbeEvents, &[{id, :stop, System.monotonic_time(:microsecond)} | &1])
  end
end
if System.get_env("PROBE_LAYOUT") == "same" do
  defmodule ProbeOne do
    use ExUnit.Case, async: true
    test "a", do: ProbeWork.run(:a)
    test "b", do: ProbeWork.run(:b)
  end
else
  defmodule ProbeOne do
    use ExUnit.Case, async: true
    test "a", do: ProbeWork.run(:a)
  end
  defmodule ProbeTwo do
    use ExUnit.Case, async: true
    test "b", do: ProbeWork.run(:b)
  end
end
result = ExUnit.run()
events = Agent.get(ProbeEvents, & &1)
time = fn id, phase -> Enum.find_value(events, fn {i, p, t} -> if i == id and p == phase, do: t end) end
overlap = max(time.(:a, :start), time.(:b, :start)) < min(time.(:a, :stop), time.(:b, :stop))
IO.puts("layout=#{System.get_env("PROBE_LAYOUT")} overlap=#{overlap} failures=#{result.failures}")
expected = System.get_env("PROBE_LAYOUT") != "same"
if overlap != expected or result.failures != 0, do: System.halt(1)
