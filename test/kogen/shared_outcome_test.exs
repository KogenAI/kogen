Code.require_file("../support/shared_outcome.ex", __DIR__)

defmodule Kogen.SharedOutcomeTest do
  use ExUnit.Case, async: true

  alias Kogen.SharedOutcome

  # Each test names its own sharing directory explicitly, so no test mutates
  # the process-wide suite variable.
  setup do
    dir =
      Path.join(System.tmp_dir!(), "kogen-shared-outcome-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "one producer's outcome is reused and a different key produces its own", %{dir: dir} do
    counter = :counters.new(1, [])
    produce = fn value -> fn -> :counters.add(counter, 1, 1) && %{value: value} end end

    assert SharedOutcome.fetch!("key-a", produce.(1), dir) == %{value: 1}
    assert SharedOutcome.fetch!("key-a", produce.(2), dir) == %{value: 1}
    assert SharedOutcome.fetch!("key-b", produce.(3), dir) == %{value: 3}
    assert :counters.get(counter, 1) == 2
  end

  test "a failed producer never blocks a rerun, which produces and fails on its own", %{dir: dir} do
    assert_raise RuntimeError, "producer failed", fn ->
      SharedOutcome.fetch!("failing", fn -> raise "producer failed" end, dir)
    end

    assert SharedOutcome.fetch!("failing", fn -> :recomputed end, dir) == :recomputed

    assert_raise RuntimeError, "rerun failed", fn ->
      SharedOutcome.fetch!("failing", fn -> raise "rerun failed" end, dir)
    end
  end

  test "without a suite directory every call produces locally" do
    assert SharedOutcome.fetch!("key-a", fn -> :first end, nil) == :first
    assert SharedOutcome.fetch!("key-a", fn -> :second end, nil) == :second
    assert SharedOutcome.fetch!("key-a", fn -> :third end, "") == :third
  end
end
