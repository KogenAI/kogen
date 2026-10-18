defmodule Mix.Tasks.Todo.Add do
  use Mix.Task

  @shortdoc "Add a task"

  @impl Mix.Task
  def run([title | _rest]) do
    Mix.Task.run("app.start")
    task = TinyTasks.add(title)
    Mix.shell().info("Added task #{task.id}: #{task.title}")
  end
end
