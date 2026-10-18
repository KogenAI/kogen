defmodule TinyTasksTest do
  use ExUnit.Case, async: false

  @project_root Path.expand("..", __DIR__)
  @mix System.find_executable("mix")

  test "BASE-1 and BASE-2: added tasks persist with stable IDs and insertion order" do
    root = Path.join(System.tmp_dir!(), "tiny-tasks-#{System.unique_integer([:positive])}")
    file = Path.join(root, "tasks.tsv")

    on_exit(fn -> File.rm_rf!(root) end)

    add_task(file, "Pay the rent")
    add_task(file, "Water the plants")
    {output, 0} = run_task(file, "todo.list", [])

    assert task_lines(output) == ["1 [open] Pay the rent", "2 [open] Water the plants"]
  end

  defp task_lines(output),
    do: output |> String.split("\n") |> Enum.filter(&Regex.match?(~r/^\d+ \[/, &1))

  defp add_task(file, title) do
    {output, 0} = run_task(file, "todo.add", [title])
    assert output =~ title
  end

  defp run_task(file, task, args) do
    System.cmd(@mix, [task | args],
      cd: @project_root,
      env: [{"TODO_FILE", file}],
      stderr_to_stdout: true
    )
  end
end
