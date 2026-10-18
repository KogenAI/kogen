defmodule TinyTasks.Store do
  def read do
    case File.read(path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path()
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

  defp decode(line) do
    [id, status, title] = String.split(line, "\t")
    %{id: String.to_integer(id), status: status, title: Base.decode64!(title)}
  end

  defp append_newline(contents, []), do: contents
  defp append_newline(contents, _tasks), do: contents <> "\n"
end
