defmodule Mix.Tasks.Todo.Complete do
  use Mix.Task

  @shortdoc "Complete a task"

  @impl Mix.Task
  def run([id]) do
    number =
      case Integer.parse(id) do
        {number, ""} -> number
        _ -> Mix.raise("Invalid task ID #{id}")
      end

    Mix.Task.run("app.start")

    case TinyTasks.complete(number) do
      :ok -> :ok
      {:error, :not_found} -> Mix.raise("Task #{id} not found")
    end
  end
end
