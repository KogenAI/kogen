defmodule TinyTasks do
  alias TinyTasks.Store

  def add(title) do
    tasks = Store.read()
    id = tasks |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
    task = %{id: id, status: "open", title: title}

    Store.write(tasks ++ [task])
    task
  end

  def complete(id) do
    tasks = Store.read()

    if Enum.any?(tasks, &(&1.id == id)) do
      Store.write(
        Enum.map(tasks, fn task ->
          if task.id == id, do: %{task | status: "done"}, else: task
        end)
      )

      :ok
    else
      {:error, :not_found}
    end
  end

  def list do
    Store.read()
  end
end
