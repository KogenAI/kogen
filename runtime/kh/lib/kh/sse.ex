defmodule Kh.SSE do
  @moduledoc "Incremental server-sent-events parser. Returns decoded `data:` payloads."

  @doc "feed(buffer, chunk) -> {[data_string], new_buffer}"
  def feed(buffer, chunk) do
    text = String.replace(buffer <> chunk, "\r\n", "\n")
    parts = String.split(text, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &event_data/1), rest}
  end

  defp event_data(block) do
    data =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> v -> String.trim_leading(v, " ") end)

    if data == [], do: [], else: [Enum.join(data, "\n")]
  end
end
