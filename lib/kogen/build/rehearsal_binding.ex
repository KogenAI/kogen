defmodule Kogen.Build.RehearsalBinding do
  @moduledoc """
  Decides whether the main suite's evidence proves a rehearsal command ran.

  A command is bound to the suite only when every `test/...` file it selects
  exists and the suite's event log holds at least one event for that file, all
  of them passed. Otherwise the command must be run itself.
  """

  @doc "Groups suite event-log JSONL bytes into `%{file => [status]}`."
  def statuses_by_file(bytes) when is_binary(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.group_by(& &1["file"], & &1["status"])
  end

  def bound?(argv, statuses_by_file, root \\ ".") do
    files =
      argv
      |> Enum.filter(&String.starts_with?(&1, "test/"))
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))

    files != [] and
      Enum.all?(files, fn file ->
        File.regular?(Path.join(root, file)) and
          match?([_ | _], Map.get(statuses_by_file, file)) and
          Enum.all?(Map.fetch!(statuses_by_file, file), &(&1 == "passed"))
      end)
  end
end
