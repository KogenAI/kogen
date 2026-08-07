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

    test "extracts dep from an em-dash-commented Blocks-on: line", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: role-loading-audit — both add the include line\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "role-loading-audit"}]
    end

    test "extracts dep from a backtick-wrapped Blocks-on: slug", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: `fix-session-log-planner-dos-bash32`\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "fix-session-log-planner-dos-bash32"}]
    end

    test "Blocks-on: (none — independent root) yields no edge", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: (none — independent root)\n")

      assert LoopQueue.parse_edges("c", path) == []
    end

    test "Blocks-on: none. <prose> yields no edge", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: none. This is the structural-enforcement sibling\n")

      assert LoopQueue.parse_edges("c", path) == []
    end

    test "a prose ## Dependencies bullet is annotation, not an edge", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "## Dependencies\n\n- **Depends on `land-elixir-loop-fixes`** — SHIPPED\n"
      )

      assert LoopQueue.parse_edges("c", path) == []
    end

    test "a bare-slug ## Dependencies bullet still yields an edge", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "## Dependencies\n\n- dep-one\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}]
    end

    test "a genuinely unmet real-slug dep still resolves to that slug", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "Blocks-on: some-draft-dep\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "some-draft-dep"}]
    end
  end

  describe "parse_edges/2 — frontmatter blocks_on:" do
    test "frontmatter blocks_on: [a, b] yields both edges in order", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on: [dep-one, dep-two]
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}, {"c", "dep-two"}]
    end

    test "frontmatter blocks_on: [a] single-item list yields one edge", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on: [dep-one]
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}]
    end

    test "frontmatter blocks_on: [] empty list yields no edge", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on: []
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == []
    end

    test "frontmatter present with no blocks_on: key yields no edge", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == []
    end

    test "frontmatter blocks_on: wins over prose Blocks-on: in the body (frontmatter-first)", %{
      dir: dir
    } do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on: [frontmatter-dep]
      ---
      # Problem

      Blocks-on: prose-dep
      """)

      assert LoopQueue.parse_edges("c", path) == [{"c", "frontmatter-dep"}]
    end

    test "no frontmatter falls back to prose Blocks-on: parse (dual-read)", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "# Problem\n\nBlocks-on: prose-dep\n")

      assert LoopQueue.parse_edges("c", path) == [{"c", "prose-dep"}]
    end

    test "ordered_slugs/1 topo-sorts correctly from frontmatter blocks_on:", %{dir: dir} do
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nblocks_on: [a]\n---\n# b\n")
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nblocks_on: []\n---\n# a\n")

      assert LoopQueue.ordered_slugs(dir) == ["a", "b"]
    end

    test "MULTILINE frontmatter blocks_on: parses every item (regression — used to silently -> [])",
         %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on:
        [
          dep-one,
          dep-two,
        ]
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}, {"c", "dep-two"}]
    end

    test "multiline frontmatter blocks_on: with a scope: key following still stops at the boundary",
         %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      blocks_on:
        [
          dep-one,
        ]
      scope:
        [
          lib/foo.ex,
        ]
      ---
      # Problem
      """)

      assert LoopQueue.parse_edges("c", path) == [{"c", "dep-one"}]
    end
  end

  describe "strip_frontmatter/1" do
    test "well-formed frontmatter is stripped, body only remains" do
      content = "---\nstatus: ready\nblocks_on: []\n---\n# Body\nline2\n"

      result = LoopQueue.strip_frontmatter(content)

      refute String.starts_with?(result, "---")
      assert result =~ "# Body"
      assert result =~ "line2"
    end

    test "plain task string with no frontmatter is returned unchanged" do
      content = "# Just a task\n\nDo the thing.\n"

      assert LoopQueue.strip_frontmatter(content) == content
    end

    test "malformed frontmatter (opens with --- but never closes) is returned unchanged" do
      content = "---\nstatus: ready\nno closing delimiter here\n"

      assert LoopQueue.strip_frontmatter(content) == content
    end
  end

  describe "parse_scope/2" do
    test "returns {:ok, nil} for a missing file", %{dir: dir} do
      assert LoopQueue.parse_scope("slug", Path.join(dir, "nope.md")) == {:ok, nil}
    end

    test "returns {:ok, nil} when no frontmatter block is present", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "# Just a task\n\nDo the thing.\n")

      assert LoopQueue.parse_scope("c", path) == {:ok, nil}
    end

    test "returns {:ok, nil} when frontmatter is present but scope: key is absent", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\n---\n# Problem\n")

      assert LoopQueue.parse_scope("c", path) == {:ok, nil}
    end

    test "inline scope: [a, b] parses both paths", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nscope: [lib/foo.ex, lib/bar.ex]\n---\n# Problem\n")

      assert LoopQueue.parse_scope("c", path) == {:ok, ["lib/foo.ex", "lib/bar.ex"]}
    end

    test "scope: [] explicit empty list parses as {:ok, []}", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nscope: []\n---\n# Problem\n")

      assert LoopQueue.parse_scope("c", path) == {:ok, []}
    end

    test "MULTILINE scope: (the only hand-written form in the corpus) parses every path",
         %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      scope:
        [
          test_harness/lib/codegen_test_harness/loop_queue.ex,
          shared/rules/_core/,
        ]
      ---
      # Problem
      """)

      assert LoopQueue.parse_scope("c", path) ==
               {:ok,
                ["test_harness/lib/codegen_test_harness/loop_queue.ex", "shared/rules/_core/"]}
    end

    test "multiline scope: followed by another top-level key stops at the boundary", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      scope:
        [
          lib/foo.ex,
        ]
      appetite: small
      ---
      # Problem
      """)

      assert LoopQueue.parse_scope("c", path) == {:ok, ["lib/foo.ex"]}
    end

    test "scope: present but not a parseable flow-list raises loud, naming the slug", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nscope: not-a-list\n---\n# Problem\n")

      assert_raise RuntimeError, ~r/c has a scope: value that is not a parseable/, fn ->
        LoopQueue.parse_scope("c", path)
      end
    end
  end

  describe "scope_report/1" do
    test "a pitch with no scope: is UNROUTED", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\n---\n# a\n")

      assert LoopQueue.scope_report(dir) == {[], [], ["a"]}
    end

    test "two pitches with disjoint scope: lists are both DISJOINT", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")

      assert LoopQueue.scope_report(dir) == {["a", "b"], [], []}
    end

    test "two pitches sharing a path are both COLLISIONS, naming the shared path", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex, lib/a.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex, lib/b.ex]\n---\n# b\n"
      )

      assert LoopQueue.scope_report(dir) == {[], [{"a", "b", ["lib/shared.ex"]}], []}
    end

    test "scope: [] explicit empty is DISJOINT, not UNROUTED", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: []\n---\n# a\n")

      assert LoopQueue.scope_report(dir) == {["a"], [], []}
    end

    test "mixed batch: collision + disjoint + unrouted all classified correctly", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# b\n"
      )

      File.write!(Path.join(dir, "c.md"), "---\nstatus: SHAPED\nscope: [lib/c.ex]\n---\n# c\n")
      File.write!(Path.join(dir, "d.md"), "---\nstatus: SHAPED\n---\n# d\n")

      assert LoopQueue.scope_report(dir) ==
               {["c"], [{"a", "b", ["lib/shared.ex"]}], ["d"]}
    end

    test "empty dir returns all-empty report", %{dir: dir} do
      assert LoopQueue.scope_report(dir) == {[], [], []}
    end
  end

  describe "partition/2" do
    test "disjoint pitches spread across lanes, largest component first", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")

      {lanes, global_hot, unrouted} = LoopQueue.partition(dir, 2)

      all_placed = lanes |> List.flatten() |> Enum.sort()
      assert all_placed == ["a", "b"]
      assert global_hot == []
      assert unrouted == []
      # each lane got exactly one of the two disjoint, equal-size pitches
      assert Enum.map(lanes, &length/1) |> Enum.sort() == [1, 1]
    end

    test "colliding pitches never split across lanes (component stays whole)", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex, lib/a.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex, lib/b.ex]\n---\n# b\n"
      )

      File.write!(Path.join(dir, "c.md"), "---\nstatus: SHAPED\nscope: [lib/c.ex]\n---\n# c\n")

      {lanes, global_hot, unrouted} = LoopQueue.partition(dir, 2)

      # a and b share lib/shared.ex -> same component -> same lane
      lane_with_a = Enum.find(lanes, &("a" in &1))
      assert "b" in lane_with_a
      assert global_hot == []
      assert unrouted == []
      assert lanes |> List.flatten() |> Enum.sort() == ["a", "b", "c"]
    end

    test "a lane's slugs are topo-sorted by their blocks_on: edges", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex]\nblocks_on: [b]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n"
      )

      {lanes, _global_hot, _unrouted} = LoopQueue.partition(dir, 1)

      assert lanes == [["b", "a"]]
    end

    test "a dead blocks_on: edge (dep outside the scoped batch) is silently ignored", %{
      dir: dir
    } do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex]\nblocks_on: [shipped-already]\n---\n# a\n"
      )

      {lanes, global_hot, unrouted} = LoopQueue.partition(dir, 1)

      assert lanes == [["a"]]
      assert global_hot == []
      assert unrouted == []
    end

    test "a pitch colliding with every other component is GLOBAL-HOT, never placed", %{
      dir: dir
    } do
      File.write!(
        Path.join(dir, "hot.md"),
        "---\nstatus: SHAPED\nscope: [lib/x.ex, lib/y.ex]\n---\n# hot\n"
      )

      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/x.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/y.ex]\n---\n# b\n")

      {lanes, global_hot, unrouted} = LoopQueue.partition(dir, 2)

      assert global_hot == ["hot"]
      refute "hot" in List.flatten(lanes)
      assert unrouted == []
    end

    test "unrouted pitches (no scope:) are never placed in a lane", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\n---\n# b\n")

      {lanes, global_hot, unrouted} = LoopQueue.partition(dir, 2)

      refute "b" in List.flatten(lanes)
      assert global_hot == []
      assert unrouted == ["b"]
    end

    test "requesting more lanes than routable pitches leaves trailing lanes empty", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")

      {lanes, _global_hot, _unrouted} = LoopQueue.partition(dir, 3)

      assert length(lanes) == 3
      assert Enum.count(lanes, &(&1 == [])) == 2
      assert List.flatten(lanes) == ["a"]
    end

    test "empty dir returns lane_count empty lanes, no global_hot, no unrouted", %{dir: dir} do
      assert LoopQueue.partition(dir, 3) == {[[], [], []], [], []}
    end

    test "raises on a non-positive lane_count" do
      assert_raise FunctionClauseError, fn -> LoopQueue.partition("ready", 0) end
      assert_raise FunctionClauseError, fn -> LoopQueue.partition("ready", -1) end
    end
  end

  describe "fleet_partition/3" do
    test "a pitch with an outgoing blocks_on: edge (even a dead one) is dependency_bound", %{
      dir: dir
    } do
      File.write!(
        Path.join(dir, "child.md"),
        "---\nstatus: SHAPED\nscope: [lib/child.ex]\nblocks_on: [shipped-elsewhere]\n---\n# child\n"
      )

      {lanes, global_hot, unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 1, MapSet.new())

      assert dependency_bound == ["child"]
      refute "child" in List.flatten(lanes)
      assert global_hot == []
      assert unrouted == []
    end

    test "a pitch named as another node's external dependency is dependency_bound", %{dir: dir} do
      File.write!(
        Path.join(dir, "prereq.md"),
        "---\nstatus: SHAPED\nscope: [lib/prereq.ex]\n---\n# prereq\n"
      )

      {lanes, global_hot, unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 1, MapSet.new(["prereq"]))

      assert dependency_bound == ["prereq"]
      refute "prereq" in List.flatten(lanes)
      assert global_hot == []
      assert unrouted == []
    end

    test "a scope-collision peer of a dependency-bound pitch is also held back", %{dir: dir} do
      File.write!(
        Path.join(dir, "child.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\nblocks_on: [external-dep]\n---\n# child\n"
      )

      File.write!(
        Path.join(dir, "peer.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# peer\n"
      )

      # A third, unrelated scoped pitch keeps child/peer from tripping the
      # separate GLOBAL-HOT classification (a slug colliding with EVERY
      # other scoped slug) — this test isolates dependency-bound peer
      # propagation, not global-hot.
      File.write!(
        Path.join(dir, "other.md"),
        "---\nstatus: SHAPED\nscope: [lib/other.ex]\n---\n# other\n"
      )

      {lanes, global_hot, _unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 1, MapSet.new())

      assert global_hot == []
      assert dependency_bound == ["child", "peer"]
      refute "child" in List.flatten(lanes)
      refute "peer" in List.flatten(lanes)
      assert "other" in List.flatten(lanes)
    end

    test "a local blocks_on: pair (both scoped, in-batch) is dependency_bound too — INVERSE of partition/2",
         %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex]\nblocks_on: [b]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n"
      )

      # partition/2 co-locates this pair into one lane (see partition/2 test
      # above: "a lane's slugs are topo-sorted by their blocks_on: edges").
      # fleet_partition/3 instead holds the whole component back — moving
      # either half across nodes could split the chain.
      {lanes, global_hot, unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 1, MapSet.new())

      assert dependency_bound == ["a", "b"]
      assert lanes == [[]]
      assert global_hot == []
      assert unrouted == []
    end

    test "independent pitches with zero fleet edges are laned normally", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")

      {lanes, global_hot, unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 2, MapSet.new())

      assert lanes |> List.flatten() |> Enum.sort() == ["a", "b"]
      assert global_hot == []
      assert unrouted == []
      assert dependency_bound == []
    end

    test "global_hot and unrouted classification is unchanged from partition/2", %{dir: dir} do
      File.write!(
        Path.join(dir, "hot.md"),
        "---\nstatus: SHAPED\nscope: [lib/x.ex, lib/y.ex]\n---\n# hot\n"
      )

      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/x.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/y.ex]\n---\n# b\n")
      File.write!(Path.join(dir, "u.md"), "---\nstatus: SHAPED\n---\n# u\n")

      {lanes, global_hot, unrouted, dependency_bound} =
        LoopQueue.fleet_partition(dir, 2, MapSet.new())

      assert global_hot == ["hot"]
      refute "hot" in List.flatten(lanes)
      assert unrouted == ["u"]
      assert dependency_bound == []
    end

    test "empty dir returns lane_count empty lanes, no global_hot/unrouted/dependency_bound", %{
      dir: dir
    } do
      assert LoopQueue.fleet_partition(dir, 3, MapSet.new()) == {[[], [], []], [], [], []}
    end

    test "raises on a non-positive lane_count" do
      assert_raise FunctionClauseError, fn ->
        LoopQueue.fleet_partition("ready", 0, MapSet.new())
      end
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

  describe "retryable_reason?/1" do
    test "reason string matching the retryable taxonomy is transient" do
      assert LoopQueue.retryable_reason?("API Error: 529 overloaded_error")
      assert LoopQueue.retryable_reason?("Connection closed mid-response")
      assert LoopQueue.retryable_reason?("socket hang up")
    end

    test "reason string with no retryable pattern is deterministic (not transient)" do
      refute LoopQueue.retryable_reason?("deterministic failure")
      refute LoopQueue.retryable_reason?("role developer-static failed twice: bad input")
    end

    test "non-binary input is deterministic (not transient), never raises" do
      refute LoopQueue.retryable_reason?(nil)
      refute LoopQueue.retryable_reason?(:some_atom)
      refute LoopQueue.retryable_reason?(%{reason: "API Error: 529"})
    end
  end

  describe "switch_model_reason?/1" do
    test "reason string matching the switch_model taxonomy is a model failure" do
      assert LoopQueue.switch_model_reason?("Claude Fable 5 is currently unavailable")
      assert LoopQueue.switch_model_reason?("model X is currently unavailable")
      assert LoopQueue.switch_model_reason?("provider acme-llm unavailable")
      assert LoopQueue.switch_model_reason?("model gpt-9 not found")
      assert LoopQueue.switch_model_reason?("unknown model requested")
    end

    test "reason string with no switch_model pattern is not a model failure" do
      refute LoopQueue.switch_model_reason?("API Error: 529 overloaded_error")
      refute LoopQueue.switch_model_reason?("deterministic failure")
      refute LoopQueue.switch_model_reason?("socket hang up")
    end

    test "non-binary input is not a model failure, never raises" do
      refute LoopQueue.switch_model_reason?(nil)
      refute LoopQueue.switch_model_reason?(:some_atom)
      refute LoopQueue.switch_model_reason?(%{reason: "unavailable"})
    end
  end

  describe "@switch_model_regex parity with harnesses/shared/retryable-errors.sh" do
    @retryable_errors_sh_for_switch Path.expand(
                                      "../../../harnesses/shared/retryable-errors.sh",
                                      __DIR__
                                    )

    test "every token in retryable-errors.sh's switch_model_regex is matched by LoopQueue.switch_model_reason?/1" do
      content = File.read!(@retryable_errors_sh_for_switch)
      [_, sh_pattern] = Regex.run(~r/^switch_model_regex='([^']*)'/m, content)

      tokens = String.split(sh_pattern, "|")
      assert length(tokens) > 0

      for token <- tokens do
        assert LoopQueue.switch_model_reason?(token),
               "token #{inspect(token)} from retryable-errors.sh's switch_model_regex is not recognized by LoopQueue.switch_model_reason?/1"
      end
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

  describe "record_ship/4" do
    setup %{dir: dir} do
      System.cmd("git", ["init", "-q", dir])
      System.cmd("git", ["-C", dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
      System.cmd("git", ["-C", dir, "config", "commit.gpgsign", "false"])

      ready_dir = Path.join([dir, "codegen", "pitches", "ready"])
      File.mkdir_p!(ready_dir)

      commit! = fn filename, message ->
        File.write!(Path.join(dir, filename), "content\n")
        System.cmd("git", ["-C", dir, "add", "."])
        System.cmd("git", ["-C", dir, "commit", "-q", "-m", message])
        {sha, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"])
        String.trim(sha)
      end

      {:ok, ready_dir: ready_dir, commit!: commit!}
    end

    test "inserts frontmatter fields on a block-carrying pitch", %{
      dir: dir,
      ready_dir: ready_dir,
      commit!: commit!
    } do
      before_sha = commit!.("a.txt", "initial")

      pitch_path = Path.join(ready_dir, "foo.md")
      File.write!(pitch_path, "---\nstatus: ready\n---\n# Pitch: foo\n")
      after_sha = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "foo", before_sha, after_sha) == :ok

      content = File.read!(pitch_path)
      assert content =~ "shipped_sha: #{after_sha}"
      assert content =~ "shipped_range: #{before_sha}..#{after_sha}"
      # Original frontmatter key survives the upsert.
      assert content =~ "status: ready"
      assert content =~ "# Pitch: foo"
    end

    test "preserves neighboring handoffs:/handoff_receipt: keys byte-for-byte", %{
      dir: dir,
      ready_dir: ready_dir,
      commit!: commit!
    } do
      before_sha = commit!.("a.txt", "initial")

      pitch_path = Path.join(ready_dir, "foo.md")
      receipt = "sha256:#{String.duplicate("a", 64)}"

      File.write!(
        pitch_path,
        "---\nstatus: ready\nhandoffs: [d::foo::other::lib/x.ex]\nhandoff_receipt: #{receipt}\n---\n# Pitch: foo\n"
      )

      after_sha = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "foo", before_sha, after_sha) == :ok

      content = File.read!(pitch_path)
      assert content =~ "handoffs: [d::foo::other::lib/x.ex]"
      assert content =~ "handoff_receipt: #{receipt}"
    end

    test "mints a frontmatter block when the pitch has none", %{
      dir: dir,
      ready_dir: ready_dir,
      commit!: commit!
    } do
      before_sha = commit!.("a.txt", "initial")

      pitch_path = Path.join(ready_dir, "bar.md")
      File.write!(pitch_path, "# Pitch: bar\n\nNo frontmatter here.\n")
      after_sha = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "bar", before_sha, after_sha) == :ok

      content = File.read!(pitch_path)
      assert String.starts_with?(content, "---\n")
      assert content =~ "shipped_sha: #{after_sha}"
      assert content =~ "shipped_range: #{before_sha}..#{after_sha}"
      assert content =~ "# Pitch: bar"
    end

    test "re-ship overwrites the field with the new sha rather than appending a duplicate", %{
      dir: dir,
      ready_dir: ready_dir,
      commit!: commit!
    } do
      before_sha = commit!.("a.txt", "initial")

      pitch_path = Path.join(ready_dir, "baz.md")
      File.write!(pitch_path, "---\nstatus: ready\n---\n# Pitch: baz\n")
      first_after = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "baz", before_sha, first_after) == :ok

      second_after = commit!.("c.txt", "third")
      assert LoopQueue.record_ship(dir, "baz", first_after, second_after) == :ok

      content = File.read!(pitch_path)
      assert content =~ "shipped_sha: #{second_after}"
      refute content =~ "shipped_sha: #{first_after}"
      # Exactly one shipped_sha: line, not two stacked from the two ships.
      assert length(Regex.scan(~r/^shipped_sha:/m, content)) == 1
    end

    test "nil after_sha (non-git/unborn carve-out): no-op, no raise", %{dir: dir} do
      assert LoopQueue.record_ship(dir, "foo", "deadbeef", nil) == :ok
    end

    test "non-git cwd: fails open, no raise", %{ready_dir: _ready_dir} do
      non_git_dir =
        Path.join(System.tmp_dir!(), "loop_queue_nongit_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(non_git_dir)
      on_exit(fn -> File.rm_rf!(non_git_dir) end)

      assert LoopQueue.record_ship(non_git_dir, "foo", "aaa", "bbb") == :ok
    end

    test "re-stamps a pitch already moved to shipped/ (post-rebase re-stamp path)", %{
      dir: dir,
      commit!: commit!
    } do
      before_sha = commit!.("a.txt", "initial")

      shipped_dir = Path.join([dir, "codegen", "pitches", "shipped"])
      File.mkdir_p!(shipped_dir)
      pitch_path = Path.join(shipped_dir, "qux.md")
      File.write!(pitch_path, "---\nstatus: ready\nshipped_sha: oldsha\n---\n# Pitch: qux\n")
      after_sha = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "qux", before_sha, after_sha) == :ok

      content = File.read!(pitch_path)
      assert content =~ "shipped_sha: #{after_sha}"
      refute content =~ "shipped_sha: oldsha"
    end

    test "stamps a pitch living in building/ (claimed, mid-cycle) — the three-path fallback",
         %{dir: dir, commit!: commit!} do
      before_sha = commit!.("a.txt", "initial")

      building_dir = Path.join([dir, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)
      pitch_path = Path.join(building_dir, "claimed.md")
      File.write!(pitch_path, "---\nstatus: ready\n---\n# Pitch: claimed\n")
      after_sha = commit!.("b.txt", "second")

      assert LoopQueue.record_ship(dir, "claimed", before_sha, after_sha) == :ok

      content = File.read!(pitch_path)
      assert content =~ "shipped_sha: #{after_sha}"
      assert content =~ "shipped_range: #{before_sha}..#{after_sha}"
    end
  end

  describe "ordered_slugs/1 — building/ is invisible to selection" do
    test "a slug that exists only in building/ is never returned" do
      dir =
        Path.join(System.tmp_dir!(), "loop_queue_building_#{:erlang.unique_integer([:positive])}")

      ready_dir = Path.join(dir, "ready")
      building_dir = Path.join(dir, "building")
      File.mkdir_p!(ready_dir)
      File.mkdir_p!(building_dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(ready_dir, "a.md"), "# a\n")
      File.write!(Path.join(building_dir, "claimed.md"), "# claimed\n")

      assert LoopQueue.ordered_slugs(ready_dir) == ["a"]
    end
  end

  describe "blocked_by_unmet_dep/2 — an in-flight (building/) dep still blocks its dependent" do
    test "a dependent whose dep is neither ready/ nor shipped/ (in building/) stays blocked" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "loop_queue_blocked_building_#{:erlang.unique_integer([:positive])}"
        )

      ready_dir = Path.join(dir, "ready")
      shipped_dir = Path.join(dir, "shipped")
      building_dir = Path.join(dir, "building")
      File.mkdir_p!(ready_dir)
      File.mkdir_p!(shipped_dir)
      File.mkdir_p!(building_dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # dependent sits in ready/, its dep is claimed (mid-cycle, in
      # building/) — neither ready/ nor shipped/ sees it, so the edge is
      # unmet and the dependent stays blocked.
      File.write!(
        Path.join(ready_dir, "dependent.md"),
        "---\nblocks_on: [dep]\n---\n# dependent\n"
      )

      File.write!(Path.join(building_dir, "dep.md"), "# dep (in flight)\n")

      blocked = LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir)
      assert Map.get(blocked, "dependent") == "dep"
    end
  end

  describe "parse_split_subject/2" do
    test "returns {:ok, nil} when the key is absent", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# c\n")

      assert LoopQueue.parse_split_subject("c", path) == {:ok, nil}
    end

    test "returns {:ok, subject} for a well-formed semicolon-separated value", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nsplit_subject: starts the loop; wakes the fleet\n---\n# c\n"
      )

      assert LoopQueue.parse_split_subject("c", path) == {:ok, "starts the loop; wakes the fleet"}
    end

    test "accepts the \" and \" clause separator", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nsplit_subject: starts the loop and wakes the fleet\n---\n# c\n"
      )

      assert LoopQueue.parse_split_subject("c", path) ==
               {:ok, "starts the loop and wakes the fleet"}
    end

    test "raises naming the slug when the value is present but single-clause", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nsplit_subject: yes\n---\n# c\n")

      assert_raise RuntimeError, ~r/c has a split_subject: value that is not two clauses/, fn ->
        LoopQueue.parse_split_subject("c", path)
      end
    end
  end

  describe "subsumed_report/1" do
    test "returns [] when no scope set is a subset of another", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")

      assert LoopQueue.subsumed_report(dir) == []
    end

    test "reports the pair when A's scope is a strict subset of B's and neither declares split_subject:",
         %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
      )

      assert LoopQueue.subsumed_report(dir) == [{"a", "b"}]
    end

    test "reports the pair when scope sets are identical", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# b\n"
      )

      assert LoopQueue.subsumed_report(dir) == [{"a", "b"}]
    end

    test "returns [] when the subsumed pitch declares split_subject:", %{dir: dir} do
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex]\nsplit_subject: starts the loop; wakes the fleet\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
      )

      assert LoopQueue.subsumed_report(dir) == []
    end

    test "returns [] when the superset pitch declares split_subject:", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n")

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\nsplit_subject: starts the loop; wakes the fleet\n---\n# b\n"
      )

      assert LoopQueue.subsumed_report(dir) == []
    end

    test "ignores scope: [] pitches entirely (no false-positive storm)", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\nscope: []\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")
      File.write!(Path.join(dir, "c.md"), "---\nstatus: SHAPED\nscope: [lib/c.ex]\n---\n# c\n")

      assert LoopQueue.subsumed_report(dir) == []
    end

    test "ignores unrouted (no scope: key) pitches", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), "---\nstatus: SHAPED\n---\n# a\n")
      File.write!(Path.join(dir, "b.md"), "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n")

      assert LoopQueue.subsumed_report(dir) == []
    end
  end

  describe "parse_handoffs/2" do
    test "returns {:ok, nil} for a missing file", %{dir: dir} do
      assert LoopQueue.parse_handoffs("slug", Path.join(dir, "nope.md")) == {:ok, nil}
    end

    test "returns {:ok, nil} when no frontmatter block is present", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "# Just a task\n\nDo the thing.\n")

      assert LoopQueue.parse_handoffs("c", path) == {:ok, nil}
    end

    test "returns {:ok, nil} when handoffs: key is absent", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\n---\n# Problem\n")

      assert LoopQueue.parse_handoffs("c", path) == {:ok, nil}
    end

    test "handoffs: [] explicit empty list parses as {:ok, []}", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nhandoffs: []\n---\n# Problem\n")

      assert LoopQueue.parse_handoffs("c", path) == {:ok, []}
    end

    test "parses a single well-formed record", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nhandoffs: [delta-1::source-a::owner-b::lib/x.ex]\n---\n# Problem\n"
      )

      assert LoopQueue.parse_handoffs("c", path) ==
               {:ok,
                [%{delta_id: "delta-1", source: "source-a", owner: "owner-b", path: "lib/x.ex"}]}
    end

    test "parses multiple records for one delta_id sharing source/owner", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(path, """
      ---
      status: SHAPED
      handoffs:
        [
          delta-1::source-a::owner-b::lib/x.ex,
          delta-1::source-a::owner-b::lib/y.ex,
        ]
      ---
      # Problem
      """)

      assert LoopQueue.parse_handoffs("c", path) ==
               {:ok,
                [
                  %{delta_id: "delta-1", source: "source-a", owner: "owner-b", path: "lib/x.ex"},
                  %{delta_id: "delta-1", source: "source-a", owner: "owner-b", path: "lib/y.ex"}
                ]}
    end

    test "raises loud on a malformed token (wrong shape)", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nhandoffs: [not-a-record]\n---\n# Problem\n")

      assert_raise RuntimeError, ~r/c has a handoffs: record that does not match/, fn ->
        LoopQueue.parse_handoffs("c", path)
      end
    end

    test "raises loud when source == owner", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nhandoffs: [delta-1::same::same::lib/x.ex]\n---\n# Problem\n"
      )

      assert_raise RuntimeError, ~r/source == owner/, fn ->
        LoopQueue.parse_handoffs("c", path)
      end
    end

    test "raises loud on a path containing ..", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nhandoffs: [delta-1::a::b::../etc/passwd]\n---\n# Problem\n"
      )

      assert_raise RuntimeError, ~r/invalid path/, fn ->
        LoopQueue.parse_handoffs("c", path)
      end
    end

    test "raises loud on a path with the reserved :: delimiter", %{dir: dir} do
      path = Path.join(dir, "c.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nhandoffs: [delta-1::a::b::lib/x::y.ex]\n---\n# Problem\n"
      )

      assert_raise RuntimeError, fn ->
        LoopQueue.parse_handoffs("c", path)
      end
    end

    test "raises loud when handoffs: is present but not a parseable flow-list", %{dir: dir} do
      path = Path.join(dir, "c.md")
      File.write!(path, "---\nstatus: SHAPED\nhandoffs: not-a-list\n---\n# Problem\n")

      assert_raise RuntimeError, ~r/c has a handoffs: value that is not a parseable/, fn ->
        LoopQueue.parse_handoffs("c", path)
      end
    end
  end

  describe "handoff_receipt/2" do
    test "is deterministic regardless of record order (sorts before hashing)" do
      r1 = %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
      r2 = %{delta_id: "d", source: "a", owner: "b", path: "lib/y.ex"}

      assert LoopQueue.handoff_receipt("a", [r1, r2]) ==
               LoopQueue.handoff_receipt("a", [r2, r1])
    end

    test "matches the sha256:<64 lowercase hex> shape" do
      r = %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
      receipt = LoopQueue.handoff_receipt("a", [r])

      assert receipt =~ ~r/^sha256:[0-9a-f]{64}$/
    end

    test "a one-byte record change produces a different digest" do
      r1 = %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
      r2 = %{delta_id: "d", source: "a", owner: "b", path: "lib/y.ex"}

      refute LoopQueue.handoff_receipt("a", [r1]) == LoopQueue.handoff_receipt("a", [r2])
    end

    test "a changed slug produces a different digest" do
      r = %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}

      refute LoopQueue.handoff_receipt("a", [r]) == LoopQueue.handoff_receipt("b", [r])
    end
  end

  describe "reconcile_handoffs/4" do
    test "returns :ok when a pitch has zero handoffs:", %{dir: dir} do
      path = Path.join(dir, "solo.md")
      File.write!(path, "---\nstatus: SHAPED\n---\n# solo\n")

      assert LoopQueue.reconcile_handoffs("solo", path, [dir]) == :ok
    end

    test "returns :ok for a matched bilateral pair with owner scope satisfied", %{dir: dir} do
      record = "delta-1::source-a::owner-b::lib/x.ex"

      File.write!(
        Path.join(dir, "source-a.md"),
        "---\nstatus: SHAPED\nhandoffs: [#{record}]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "owner-b.md"),
        "---\nstatus: SHAPED\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
      )

      assert LoopQueue.reconcile_handoffs("source-a", Path.join(dir, "source-a.md"), [dir]) ==
               :ok
    end

    test "errors when the counterpart participant is missing", %{dir: dir} do
      record = "delta-1::source-a::owner-b::lib/x.ex"

      File.write!(
        Path.join(dir, "source-a.md"),
        "---\nstatus: SHAPED\nhandoffs: [#{record}]\n---\n# a\n"
      )

      assert {:error, msg} =
               LoopQueue.reconcile_handoffs("source-a", Path.join(dir, "source-a.md"), [dir])

      assert msg =~ "HANDOFF GAP delta-1"
      assert msg =~ "owner-b"
    end

    test "errors when the counterpart's copy of the record does not match", %{dir: dir} do
      File.write!(
        Path.join(dir, "source-a.md"),
        "---\nstatus: SHAPED\nhandoffs: [delta-1::source-a::owner-b::lib/x.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "owner-b.md"),
        "---\nstatus: SHAPED\nscope: [lib/x.ex]\nhandoffs: [delta-1::source-a::owner-b::lib/y.ex]\n---\n# b\n"
      )

      assert {:error, msg} =
               LoopQueue.reconcile_handoffs("source-a", Path.join(dir, "source-a.md"), [dir])

      assert msg =~ "HANDOFF GAP delta-1"
      assert msg =~ "identical copy"
    end

    test "errors when the owner's scope: does not list the path", %{dir: dir} do
      record = "delta-1::source-a::owner-b::lib/x.ex"

      File.write!(
        Path.join(dir, "source-a.md"),
        "---\nstatus: SHAPED\nhandoffs: [#{record}]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "owner-b.md"),
        "---\nstatus: SHAPED\nscope: [lib/other.ex]\nhandoffs: [#{record}]\n---\n# b\n"
      )

      assert {:error, msg} =
               LoopQueue.reconcile_handoffs("source-a", Path.join(dir, "source-a.md"), [dir])

      assert msg =~ "HANDOFF GAP delta-1"
      assert msg =~ "does not list"
    end

    test "terminates on a graph cycle via the visited set", %{dir: dir} do
      # a -> b -> a: a lists a record with b as counterpart; b lists a
      # record with a as counterpart. Different delta_ids so they are
      # independent edges, not a duplicate-ID conflict.
      File.write!(
        Path.join(dir, "a.md"),
        "---\nstatus: SHAPED\nscope: [lib/b-owns.ex]\nhandoffs: [d1::b::a::lib/b-owns.ex, d2::a::b::lib/a-owns.ex]\n---\n# a\n"
      )

      File.write!(
        Path.join(dir, "b.md"),
        "---\nstatus: SHAPED\nscope: [lib/a-owns.ex]\nhandoffs: [d1::b::a::lib/b-owns.ex, d2::a::b::lib/a-owns.ex]\n---\n# b\n"
      )

      assert LoopQueue.reconcile_handoffs("a", Path.join(dir, "a.md"), [dir]) == :ok
    end
  end

  describe "write_handoff_receipt!/3" do
    test "mints handoff_receipt: into a pitch with no receipt", %{dir: dir} do
      path = Path.join(dir, "a.md")
      content = "---\nstatus: SHAPED\nhandoffs: [d::a::b::lib/x.ex]\n---\n# a\n"
      File.write!(path, content)

      receipt =
        LoopQueue.handoff_receipt("a", [
          %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
        ])

      assert LoopQueue.write_handoff_receipt!(path, content, receipt) == :ok
      assert File.read!(path) =~ "handoff_receipt: #{receipt}"
    end

    test "replaces a stale existing receipt in place", %{dir: dir} do
      path = Path.join(dir, "a.md")

      content =
        "---\nstatus: SHAPED\nhandoffs: [d::a::b::lib/x.ex]\nhandoff_receipt: sha256:#{String.duplicate("0", 64)}\n---\n# a\n"

      File.write!(path, content)

      new_receipt =
        LoopQueue.handoff_receipt("a", [
          %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
        ])

      assert LoopQueue.write_handoff_receipt!(path, content, new_receipt) == :ok

      updated = File.read!(path)
      assert updated =~ "handoff_receipt: #{new_receipt}"
      refute updated =~ String.duplicate("0", 64)
    end

    test "a source-byte race between precompute and write aborts, leaving the original intact",
         %{dir: dir} do
      path = Path.join(dir, "a.md")
      original = "---\nstatus: SHAPED\nhandoffs: [d::a::b::lib/x.ex]\n---\n# a\n"
      File.write!(path, original)

      # Model the race: caller precomputed `original` as expected_content, but
      # the file was mutated on disk before the write call happens.
      File.write!(path, "---\nstatus: SHAPED\nhandoffs: [d::a::b::lib/y.ex]\n---\n# a\n")

      receipt =
        LoopQueue.handoff_receipt("a", [
          %{delta_id: "d", source: "a", owner: "b", path: "lib/x.ex"}
        ])

      assert LoopQueue.write_handoff_receipt!(path, original, receipt) == {:error, :stale}
      refute File.read!(path) =~ "handoff_receipt:"
    end

    test "raises on a malformed receipt argument", %{dir: dir} do
      path = Path.join(dir, "a.md")
      content = "---\nstatus: SHAPED\n---\n# a\n"
      File.write!(path, content)

      assert_raise RuntimeError, ~r/not a well-formed sha256/, fn ->
        LoopQueue.write_handoff_receipt!(path, content, "not-a-receipt")
      end
    end
  end

  # ── write_build_failures!/3 — append_history_row/3's line-start anchor ────
  # Regression coverage for "build-record-matches-what-happened" M3:
  # append_history_row/3 previously located its `## <header>` marker via a
  # bare String.contains?/String.split, which matches ANY substring
  # occurrence — including a prose mention of the heading text earlier in
  # the pitch body. append_history_row/3 itself has no direct test (it is
  # `defp`); these tests exercise it through its two public callers.
  describe "write_build_failures!/3 — Build failure history marker anchoring" do
    test "a prose line matching the marker text earlier in the file does NOT hijack the row",
         %{dir: dir} do
      path = Path.join(dir, "a.md")

      body =
        "---\nstatus: SHAPED\n---\n# a\n\n" <>
          "## Solution sketch\n\n" <>
          "The row lands under `## Build failure history` in the pitch.\n\n" <>
          "## Dependencies\n\nSome deps.\n\n" <>
          "## Build failure history\n\n" <>
          "| run | when | cost | terminal reason |\n|---|---|---|---|\n"

      File.write!(path, body)

      assert :ok = LoopQueue.write_build_failures!(path, 1, "| queue drain | NEWROW |")

      updated = File.read!(path)

      # The new row must land AFTER "## Dependencies", inside the REAL
      # section — never spliced into the prose mention above it.
      [_before_deps, after_deps] = String.split(updated, "## Dependencies", parts: 2)
      assert after_deps =~ "| queue drain | NEWROW |"

      [before_real_heading, _] = String.split(updated, "## Build failure history", parts: 2)
      refute before_real_heading =~ "NEWROW"
    end

    test "mints the section at EOF when none exists, unchanged from prior behavior", %{dir: dir} do
      path = Path.join(dir, "a.md")
      File.write!(path, "---\nstatus: SHAPED\n---\n# a\n\n## Problem\n\nNo history section.\n")

      assert :ok = LoopQueue.write_build_failures!(path, 1, "| queue drain | ROW1 |")

      updated = File.read!(path)
      assert updated =~ "## Build failure history"
      assert updated =~ "| run | when | cost | terminal reason |"
      assert updated =~ "| queue drain | ROW1 |"
    end

    test "a second failure appends inside the EXISTING section, preserving the first row",
         %{dir: dir} do
      path = Path.join(dir, "a.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nbuild_failures: 1\n---\n# a\n\n" <>
          "## Build failure history\n\n" <>
          "| run | when | cost | terminal reason |\n|---|---|---|---|\n" <>
          "| queue drain | ROW1 |\n"
      )

      assert :ok = LoopQueue.write_build_failures!(path, 2, "| queue drain | ROW2 |")

      updated = File.read!(path)
      assert updated =~ "build_failures: 2"
      assert updated =~ "| queue drain | ROW1 |"
      assert updated =~ "| queue drain | ROW2 |"

      rows =
        updated |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| queue drain"))

      assert length(rows) == 2
    end
  end

  # ── record_counted_history!/3 — the context-free counted write M6/M8 wire
  # InterruptedCycleRecovery through. Regression coverage for
  # "build-record-matches-what-happened" M8: below max_pitch_fails_from_env/0
  # the row is appended in place; AT the threshold the pitch is demoted to
  # draft/ with status: SHAPING and the full history preserved — this is the
  # exact branch that produced the 107-row crash loop when it was bypassed.
  describe "record_counted_history!/3" do
    test "below threshold: appends the row in place and returns the incremented count",
         %{dir: dir} do
      pitch_path = Path.join(dir, "solo.md")
      draft_dir = Path.join(dir, "draft")

      File.write!(
        pitch_path,
        "---\nstatus: SHAPED\n---\n# solo\n\n## Build failure history\n\n" <>
          "| run | when | cost | terminal reason |\n|---|---|---|---|\n"
      )

      assert LoopQueue.record_counted_history!(
               pitch_path,
               draft_dir,
               "| interrupted recovery | ROW1 |"
             ) == 1

      assert File.exists?(pitch_path)
      refute File.exists?(Path.join(draft_dir, "solo.md"))
      updated = File.read!(pitch_path)
      assert updated =~ "build_failures: 1"
      assert updated =~ "| interrupted recovery | ROW1 |"
      refute updated =~ "status: SHAPING"
    end

    test "at max_pitch_fails_from_env/0's threshold: demotes to draft/ with status: SHAPING and preserves history",
         %{dir: dir} do
      ready_dir = Path.join(dir, "ready")
      draft_dir = Path.join(dir, "draft")
      File.mkdir_p!(ready_dir)
      pitch_path = Path.join(ready_dir, "solo.md")

      # Pre-seeded at count 1 (one prior counted attempt already recorded),
      # mirroring the loop_queue_drain_test.exs pattern for driving
      # write_demotion!/5 — this call is the SECOND physical attempt, which
      # reaches max_pitch_fails_from_env/0's default threshold of 2.
      File.write!(
        pitch_path,
        "---\nstatus: SHAPED\nbuild_failures: 1\n---\n# solo\n\n## Build failure history\n\n" <>
          "| run | when | cost | terminal reason |\n|---|---|---|---|\n" <>
          "| interrupted recovery | ROW1 |\n"
      )

      assert LoopQueue.record_counted_history!(
               pitch_path,
               draft_dir,
               "| interrupted recovery | ROW2 |"
             ) == 2

      refute File.exists?(pitch_path)
      draft_path = Path.join(draft_dir, "solo.md")
      assert File.exists?(draft_path)

      demoted = File.read!(draft_path)
      assert demoted =~ "build_failures: 2"
      assert demoted =~ "status: SHAPING"
      # Both rows survive the demotion — the pitch carries its FULL counted
      # history into draft/ for the reshaper, not just the demoting row.
      assert demoted =~ "| interrupted recovery | ROW1 |"
      assert demoted =~ "| interrupted recovery | ROW2 |"
    end
  end
end

# Sibling module, async: false — CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS is
# process-global env state (System.put_env), so it cannot run concurrently
# with any other test in this suite that reads
# LoopQueue.max_pitch_fails_from_env/0's default via an unset env var.
defmodule CodegenTestHarness.LoopQueueEnvSerialTest do
  use ExUnit.Case, async: false

  alias CodegenTestHarness.LoopQueue

  setup do
    dir =
      Path.join(System.tmp_dir!(), "loop_queue_env_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "record_counted_history!/3 — CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS" do
    test "honors the env var when set below the default", %{dir: dir} do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS", "1")

      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS") end)

      ready_dir = Path.join(dir, "ready")
      draft_dir = Path.join(dir, "draft")
      File.mkdir_p!(ready_dir)
      pitch_path = Path.join(ready_dir, "solo.md")
      File.write!(pitch_path, "---\nstatus: SHAPED\n---\n# solo\n")

      # With the threshold lowered to 1, the FIRST counted attempt already
      # demotes — proves record_counted_history!/3 reads the threshold via
      # max_pitch_fails_from_env/0 rather than a hardcoded default.
      assert LoopQueue.record_counted_history!(
               pitch_path,
               draft_dir,
               "| interrupted recovery | ROW1 |"
             ) == 1

      refute File.exists?(pitch_path)
      draft_path = Path.join(draft_dir, "solo.md")
      assert File.exists?(draft_path)
      assert File.read!(draft_path) =~ "status: SHAPING"
    end
  end
end
