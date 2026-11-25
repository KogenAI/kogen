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

  test "TASK-1: completing a task preserves the ordered list and other fields" do
    root = Path.join(System.tmp_dir!(), "tiny-tasks-#{System.unique_integer([:positive])}")
    file = Path.join(root, "tasks.tsv")
    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(["Pay the rent", "Water the plants", "Take out recycling"], &add_task(file, &1))
    before = File.read!(file)
    {_, 0} = run_task(file, "todo.complete", ["2"])
    {output, 0} = run_task(file, "todo.list", [])

    assert task_lines(output) == [
             "1 [open] Pay the rent",
             "2 [done] Water the plants",
             "3 [open] Take out recycling"
           ]

    assert File.read!(file) == String.replace(before, "2\topen\t", "2\tdone\t")
  end

  test "TASK-1: an unknown ID fails without writing the file" do
    root = Path.join(System.tmp_dir!(), "tiny-tasks-#{System.unique_integer([:positive])}")
    file = Path.join(root, "tasks.tsv")
    on_exit(fn -> File.rm_rf!(root) end)

    add_task(file, "Pay the rent")
    before = File.read!(file)
    # Set an old timestamp so even an identical in-place rewrite is observable.
    File.touch!(file, {{2000, 1, 1}, {0, 0, 0}})
    stat = File.stat!(file)
    {output, status} = run_task(file, "todo.complete", ["99"])

    assert status != 0
    assert output =~ "99"
    assert File.read!(file) == before
    after_stat = File.stat!(file)
    assert after_stat.inode == stat.inode
    assert after_stat.mtime == stat.mtime
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
