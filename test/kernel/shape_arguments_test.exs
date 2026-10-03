defmodule Kogen.Kernel.ShapeArgumentsTest do
  use ExUnit.Case, async: true

  alias Kogen.Kernel.CLI.Args
  alias Kogen.Kernel.CLI.Arguments

  test "intent shape defaults to the Build model and effort" do
    assert {:ok, %Args{} = args} =
             Arguments.parse([
               "intent",
               "shape",
               "new-feature",
               "--task-file",
               "/tmp/task.md",
               "--project",
               "/tmp/project",
               "--json"
             ])

    assert args.command == :intent_shape
    assert args.task_file == "/tmp/task.md"
    assert args.model == "gpt-6-luna"
    assert args.effort == "max"
    assert args.json
  end

  test "intent shape requires a task file" do
    assert {:error, "intent shape requires --task-file"} =
             Arguments.parse(["intent", "shape", "new-feature"])
  end
end
