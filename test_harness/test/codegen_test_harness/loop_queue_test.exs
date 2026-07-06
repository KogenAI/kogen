defmodule CodegenTestHarness.LoopQueueTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.LoopQueue

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_queue_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "ordered_slugs/1" do
    test "orders deps first via Blocks-on:", %{dir: dir} do
      File.write!(Path.join(dir, "b.md"), "# Pitch: b\n\nBlocks-on: a\n")
      File.write!(Path.join(dir, "a.md"), "# Pitch: a\n")

      assert LoopQueue.ordered_slugs(dir) == ["a", "b"]
    end

    test "orders deps first via ## Dependencies bullet list", %{dir: dir} do
      File.write!(Path.join(dir, "b.md"), "# Pitch: b\n\n## Dependencies\n\n- a\n")
      File.write!(Path.join(dir, "a.md"), "# Pitch: a\n")

      assert LoopQueue.ordered_slugs(dir) == ["a", "b"]
    end

    test "independent pitches keep lexical order", %{dir: dir} do
      File.write!(Path.join(dir, "z.md"), "# Pitch: z\n")
      File.write!(Path.join(dir, "a.md"), "# Pitch: a\n")

      assert LoopQueue.ordered_slugs(dir) == ["a", "z"]
    end

    test "ignores edges to a dep outside the batch", %{dir: dir} do
      File.write!(Path.join(dir, "b.md"), "# Pitch: b\n\nBlocks-on: not-in-batch\n")

      assert LoopQueue.ordered_slugs(dir) == ["b"]
    end

    test "raises on a dependency cycle", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "# Pitch: a\n\nBlocks-on: b\n")
      File.write!(Path.join(dir, "b.md"), "# Pitch: b\n\nBlocks-on: a\n")

      assert_raise RuntimeError, ~r/cyclic dependency/, fn ->
        LoopQueue.ordered_slugs(dir)
      end
    end

    test "empty dir returns empty list", %{dir: dir} do
      assert LoopQueue.ordered_slugs(dir) == []
    end
  end

  describe "parse_edges/2" do
    test "returns [] for a missing file", %{dir: dir} do
      assert LoopQueue.parse_edges("slug", Path.join(dir, "nope.md")) == []
    end

    test "extracts the first dep only from a comma list (matches build-queue.sh)", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: dep-one, dep-two\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}]
    end
  end

  describe "blocked_by_unmet_dep/2" do
    setup %{dir: dir} do
      ready_dir = Path.join(dir, "ready")
      shipped_dir = Path.join(dir, "shipped")
      File.mkdir_p!(ready_dir)
      File.mkdir_p!(shipped_dir)
      {:ok, ready_dir: ready_dir, shipped_dir: shipped_dir}
    end

    test "dep in draft/absent (neither ready nor shipped) -> blocked", %{
      ready_dir: ready_dir,
      shipped_dir: shipped_dir
    } do
      File.write!(Path.join(ready_dir, "b.md"), "# Pitch: b\n\nBlocks-on: draft-dep\n")

      assert LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir) == %{"b" => "draft-dep"}
    end

    test "dep present in shipped/ -> satisfied, not blocked", %{
      ready_dir: ready_dir,
      shipped_dir: shipped_dir
    } do
      File.write!(Path.join(shipped_dir, "sdep.md"), "# Pitch: sdep\n")
      File.write!(Path.join(ready_dir, "b.md"), "# Pitch: b\n\nBlocks-on: sdep\n")

      assert LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir) == %{}
    end

    test "dep present intra-batch in ready/ -> satisfied, not blocked (topo handles ordering)", %{
      ready_dir: ready_dir,
      shipped_dir: shipped_dir
    } do
      File.write!(Path.join(ready_dir, "a.md"), "# Pitch: a\n")
      File.write!(Path.join(ready_dir, "b.md"), "# Pitch: b\n\nBlocks-on: a\n")

      assert LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir) == %{}
    end

    test "no deps -> not blocked (absent from map)", %{
      ready_dir: ready_dir,
      shipped_dir: shipped_dir
    } do
      File.write!(Path.join(ready_dir, "a.md"), "# Pitch: a\n")

      assert LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir) == %{}
    end
  end

  describe "topo_sort/2" do
    test "deps-first ordering with a 3-node chain" do
      assert LoopQueue.topo_sort(["a", "b", "c"], [{"c", "b"}, {"b", "a"}]) == ["a", "b", "c"]
    end

    test "raises on cycle" do
      assert_raise RuntimeError, ~r/cyclic dependency/, fn ->
        LoopQueue.topo_sort(["a", "b"], [{"a", "b"}, {"b", "a"}])
      end
    end
  end

  describe "transient?/1" do
    test "missing file is transient (crashed/killed mid-flight)", %{dir: dir} do
      assert LoopQueue.transient?(Path.join(dir, "missing.jsonl"))
    end

    test "retryable_regex match is transient", %{dir: dir} do
      path = Path.join(dir, "a.jsonl")
      File.write!(path, ~s({"type":"result"}\nAPI Error: 529 overloaded\n))

      assert LoopQueue.transient?(path)
    end

    test "no type:result record is transient (crashed mid-flight)", %{dir: dir} do
      path = Path.join(dir, "b.jsonl")
      File.write!(path, ~s({"type":"assistant","message":"partial"}\n))

      assert LoopQueue.transient?(path)
    end

    test "clean result with no retryable pattern is deterministic (not transient)", %{dir: dir} do
      path = Path.join(dir, "c.jsonl")
      File.write!(path, ~s({"type":"result","result":"some clean failure"}\n))

      refute LoopQueue.transient?(path)
    end
  end

  describe "@retryable_regex parity with harnesses/shared/retryable-errors.sh" do
    @retryable_errors_sh Path.expand(
                           "../../../harnesses/shared/retryable-errors.sh",
                           __DIR__
                         )

    test "every token in retryable-errors.sh's retryable_regex is matched by LoopQueue.transient?/1" do
      assert File.exists?(@retryable_errors_sh),
             "harnesses/shared/retryable-errors.sh not found at #{@retryable_errors_sh}"

      content = File.read!(@retryable_errors_sh)

      # Extract the single-quoted retryable_regex='...' assignment (kept on
      # one physical line per the shared parity contract).
      [_, sh_pattern] = Regex.run(~r/^retryable_regex='([^']*)'/m, content)

      tokens = String.split(sh_pattern, "|")
      assert length(tokens) > 0

      for token <- tokens do
        dir = Path.join(System.tmp_dir!(), "parity_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        path = Path.join(dir, "t.jsonl")
        # No "type":"result" record present is itself transient (crashed
        # mid-flight) — so embed a benign result record first, then the
        # token on its own line, to isolate the regex-match branch.
        File.write!(path, ~s({"type":"result","result":"ok"}\n) <> token <> "\n")

        assert LoopQueue.transient?(path),
               "token #{inspect(token)} from retryable-errors.sh is not recognized as transient by LoopQueue.transient?/1"

        File.rm_rf!(dir)
      end
    end

    test "LoopQueue's @retryable_regex source has the same token count as retryable-errors.sh" do
      content = File.read!(@retryable_errors_sh)
      [_, sh_pattern] = Regex.run(~r/^retryable_regex='([^']*)'/m, content)
      sh_tokens = String.split(sh_pattern, "|") |> Enum.sort()

      # Read loop_queue.ex's own source to extract its @retryable_regex
      # literal tokens (rather than introspecting the compiled Regex, whose
      # source string may differ in escaping) — mirrors the sh-side parse.
      loop_queue_ex =
        Path.expand("../../lib/codegen_test_harness/loop_queue.ex", __DIR__)

      ex_content = File.read!(loop_queue_ex)
      [_, ex_pattern] = Regex.run(~r/@retryable_regex ~r\/([^\/]*)\//, ex_content)
      ex_tokens = String.split(ex_pattern, "|") |> Enum.sort()

      assert ex_tokens == sh_tokens
    end
  end
end
