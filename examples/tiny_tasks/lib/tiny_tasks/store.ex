defmodule TinyTasks.Store do
  def read do
    file = path()

    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _number} -> line == "" end)
        |> Enum.map(fn {line, number} -> decode(line, file, number) end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: file
    end
  end

  def write(tasks) do
    file = path()
    File.mkdir_p!(Path.dirname(file))

    contents =
      tasks
      |> Enum.map_join("\n", &encode/1)
      |> append_newline(tasks)

    File.write!(file, contents)
  end

  defp path do
    System.get_env("TODO_FILE") || Path.join([System.user_home!(), ".tiny_tasks", "tasks.tsv"])
  end

  defp encode(task) do
    [Integer.to_string(task.id), task.status, Base.encode64(task.title)]
    |> Enum.join("\t")
  end

  defp decode(line, file, number) do
    with [id, status, title] <- String.split(line, "\t"),
         {id, ""} <- Integer.parse(id) do
      %{id: id, status: status, title: Base.decode64!(title)}
    else
      _ -> Mix.raise("Malformed task row at #{file}:#{number}")
    end
  end

  defp append_newline(contents, []), do: contents
  defp append_newline(contents, _tasks), do: contents <> "\n"
end
