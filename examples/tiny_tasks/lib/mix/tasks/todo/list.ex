defmodule Mix.Tasks.Todo.List do
  use Mix.Task

  @shortdoc "List tasks"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case TinyTasks.list() do
      [] -> Mix.shell().info("No tasks yet.")
      tasks -> Enum.each(tasks, &print_task/1)
    end
  end

  defp print_task(task) do
    Mix.shell().info("#{task.id} [#{task.status}] #{task.title}")
  end
end
