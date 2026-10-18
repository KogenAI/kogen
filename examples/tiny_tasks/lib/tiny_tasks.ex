defmodule TinyTasks do
  alias TinyTasks.Store

  def add(title) do
    tasks = Store.read()
    id = tasks |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
    task = %{id: id, status: "open", title: title}

    Store.write(tasks ++ [task])
    task
  end

  def list do
    Store.read()
  end
end
