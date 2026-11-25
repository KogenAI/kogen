defmodule Mix.Tasks.Todo.Complete do
  use Mix.Task

  @shortdoc "Complete a task"

  @impl Mix.Task
  def run([id]) do
    Mix.Task.run("app.start")

    case TinyTasks.complete(String.to_integer(id)) do
      :ok -> :ok
      {:error, :not_found} -> Mix.raise("Task #{id} not found")
    end
  end
end
