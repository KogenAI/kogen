defmodule Kogen.TimingFormatter do
  @moduledoc false
  use GenServer

  def init(_options), do: {:ok, []}

  def handle_cast({:test_finished, test}, timings) do
    entry = {test.time || 0, test.module, test.name}
    {:noreply, [entry | timings]}
  end

  def handle_cast({:suite_finished, _times}, timings) do
    IO.puts("\nSlowest individual offline cases (includes isolated process startup):")

    timings
    |> Enum.sort(:desc)
    |> Enum.take(8)
    |> Enum.each(fn {microseconds, module, name} ->
      IO.puts("  #{Float.round(microseconds / 1_000_000, 3)}s #{inspect(module)} #{name}")
    end)

    {:noreply, timings}
  end

  def handle_cast(_event, timings), do: {:noreply, timings}
end
