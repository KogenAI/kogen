defmodule Mix.Tasks.Todo.List do
  use Mix.Task

  @shortdoc "List tasks"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    tasks = TinyTasks.list()
    tasks = if args == ["--open"], do: Enum.filter(tasks, &(&1.status == "open")), else: tasks

    case tasks do
      [] -> Mix.shell().info("No tasks yet.")
      tasks -> Enum.each(tasks, &print_task/1)
    end
  end

  defp print_task(task) do
    Mix.shell().info("#{task.id} [#{task.status}] #{task.title}")
  end
end
