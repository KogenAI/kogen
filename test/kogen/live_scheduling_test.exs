defmodule Kogen.LiveSchedulingTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/scheduling_overlap_probe.exs", __DIR__)
  @live_source Path.expand("live_shape_to_build_test.exs", __DIR__)

  test "actual isolated dispatchers overlap across the two live owner modules" do
    {root, output, status} = run_probe()
    on_exit(fn -> File.rm_rf!(root) end)

    assert status == 0, output

    assert File.read!(Path.join(root, "rendezvous/connected.steps")) ==
             "started\ndependent-finished\n"

    assert File.read!(Path.join(root, "rendezvous/rework.steps")) ==
             "started\ndependent-finished\n"

    assert Path.wildcard(Path.join(root, "tmp/kogen-isolated-*")) == []
  end

  test "an isolated owner failure reaches the scheduling suite and cleanup still settles" do
    {root, output, status} = run_probe("connected")
    on_exit(fn -> File.rm_rf!(root) end)

    assert status != 0
    assert output =~ "requested connected owner failure"
    assert Path.wildcard(Path.join(root, "tmp/kogen-isolated-*")) == []
  end

  test "live selection keeps connected and rework owners in distinct async modules" do
    source = File.read!(@live_source)

    assert source =~ "defmodule Kogen.LiveShapeToBuildTest do"
    assert source =~ "defmodule Kogen.LiveReviewerReworkTest do"
    assert length(Regex.scan(~r/use ExUnit.Case, async: true/, source)) == 2
    assert source =~ "def run_reviewer_rework_case do"
    assert source =~ "Kogen.LiveShapeToBuildTest.run_reviewer_rework_case()"
  end

  defp run_probe(failing_owner \\ "") do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-scheduling-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    rendezvous = Path.join(root, "rendezvous")
    tmp = Path.join(root, "tmp")
    File.mkdir_p!(rendezvous)
    File.mkdir_p!(tmp)

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.reject(&String.contains?(&1, "kogen-test-code-"))
      |> Enum.uniq()

    args =
      Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++
        ["-r", Path.expand("../test_helper.exs", __DIR__), @probe]

    {output, status} =
      System.cmd("elixir", args,
        env: [
          {"SCHEDULING_RENDEZVOUS", rendezvous},
          {"SCHEDULING_FAIL", failing_owner},
          {"TMPDIR", tmp}
        ],
        stderr_to_stdout: true
      )

    {root, output, status}
  end
end
