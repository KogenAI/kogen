defmodule Mix.Tasks.Codegen.LoopTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Codegen.Loop

  setup do
    tmp = Path.join(System.tmp_dir!(), "codegen_loop_test_#{:erlang.unique_integer([:positive])}")
    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    building_dir = Path.join([tmp, "codegen", "pitches", "building"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir, building_dir: building_dir}
  end

  test "1: @-prefixed relative path resolves against cwd", ctx do
    body = "# Pitch: x\n"
    File.write!(Path.join(ctx.ready_dir, "x.md"), body)

    assert Loop.resolve_pitch("@codegen/pitches/ready/x.md", ctx.tmp) == body
  end

  test "2: bare-relative path (pi convention) resolves against cwd", ctx do
    body = "# Pitch: x\n"
    File.write!(Path.join(ctx.ready_dir, "x.md"), body)

    assert Loop.resolve_pitch("codegen/pitches/ready/x.md", ctx.tmp) == body
  end

  test "3: absolute @-prefixed path passes through, cwd ignored", ctx do
    body = "# Pitch: x\n"
    abs = Path.join(ctx.ready_dir, "x.md")
    File.write!(abs, body)

    assert Loop.resolve_pitch("@" <> abs, "/nonexistent/other/cwd") == body
  end

  test "5: literal (non-file) prompt text passes through unchanged", ctx do
    assert Loop.resolve_pitch("just some prompt text", ctx.tmp) == "just some prompt text"
  end

  test "6: @-prefixed pitch with YAML frontmatter resolves to body only", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "x.md"),
      "---\nstatus: SHAPED\nblocks_on: []\n---\n# Pitch: x\n\nBody text.\n"
    )

    result = Loop.resolve_pitch("@codegen/pitches/ready/x.md", ctx.tmp)

    refute String.starts_with?(result, "---")
    assert result =~ "# Pitch: x"
    assert result =~ "Body text."
  end

  describe "maybe_ship_pitch/4" do
    test "happy-path move: ready file moves to shipped, content preserved", ctx do
      body = "# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok
      refute File.exists?(abs)
      assert File.exists?(shipped_path)
      assert File.read!(shipped_path) == body
    end

    test "idempotent rerun: source already shipped, no crash", ctx do
      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])
      File.mkdir_p!(shipped_dir)
      shipped_path = Path.join(shipped_dir, "foo.md")
      File.write!(shipped_path, "# Pitch: foo\n")

      missing_abs = Path.join(ctx.ready_dir, "foo.md")

      assert Loop.maybe_ship_pitch({:file, missing_abs}, ctx.tmp) == :ok
      assert File.exists?(shipped_path)
    end

    test "error-path invariant: pitch left in ready/ when maybe_ship_pitch is not called", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert File.exists?(abs)
    end

    test "literal prompt text: no move, nothing created", ctx do
      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])

      assert Loop.maybe_ship_pitch(:literal, ctx.tmp) == :ok
      refute File.exists?(shipped_dir)
      assert File.ls!(ctx.ready_dir) == []
    end

    test "non-ready-dir file: no move, file stays at original path", ctx do
      elsewhere_dir = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere_dir)
      abs = Path.join(elsewhere_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok
      assert File.exists?(abs)
      refute File.exists?(shipped_dir)
    end

    test "nil after_sha (non-git / unborn cwd): ships without recording, no raise", ctx do
      body = "# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp, nil, nil) == :ok

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.read!(shipped_path) == body
    end
  end

  describe "claim_pitch!/2 — possession by rename" do
    test "moves ready/<slug>.md to building/<slug>.md and returns the new path", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.claim_pitch!({:file, abs}, ctx.tmp) ==
               {:file, Path.join([ctx.tmp, "codegen", "pitches", "building", "foo.md"])}

      refute File.exists?(abs)
      assert File.exists?(Path.join([ctx.tmp, "codegen", "pitches", "building", "foo.md"]))
    end

    test "literal source passes through unchanged, nothing claimed", ctx do
      assert Loop.claim_pitch!(:literal, ctx.tmp) == :literal
    end

    test "a file outside ready/ passes through unchanged", ctx do
      elsewhere = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      abs = Path.join(elsewhere, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.claim_pitch!({:file, abs}, ctx.tmp) == {:file, abs}
      assert File.exists?(abs)
    end
  end

  describe "restore_claim/2 — diff-failure restores building/ back to ready/" do
    test "moves building/<slug>.md back to ready/<slug>.md", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      {:file, building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)

      assert Loop.restore_claim({:file, building_abs}, ctx.tmp) == :ok

      refute File.exists?(building_abs)
      assert File.exists?(abs)
      assert File.read!(abs) == "# Pitch: foo\n"
    end

    test "literal source: no-op", ctx do
      assert Loop.restore_claim(:literal, ctx.tmp) == :ok
    end

    test "a file not in building/: no-op, no crash", ctx do
      elsewhere = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      abs = Path.join(elsewhere, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.restore_claim({:file, abs}, ctx.tmp) == :ok
      assert File.exists?(abs)
    end
  end

  describe "maybe_ship_pitch/4 — building/ source (the normal claimed path)" do
    test "ships a pitch whose source is building/<slug>.md into shipped/", ctx do
      building_dir = Path.join([ctx.tmp, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)
      abs = Path.join(building_dir, "foo.md")
      body = "# Pitch: foo\n"
      File.write!(abs, body)

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok

      refute File.exists?(abs)
      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.exists?(shipped_path)
      assert File.read!(shipped_path) == body
    end
  end

  describe "verify_commit_landed/2 — solo ship-gate floor" do
    defp init_git_repo!(cwd) do
      System.cmd("git", ["init", "-q", cwd])
      System.cmd("git", ["-C", cwd, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", cwd, "config", "user.name", "Test"])
      System.cmd("git", ["-C", cwd, "config", "commit.gpgsign", "false"])
    end

    defp commit!(cwd, filename, message) do
      File.write!(Path.join(cwd, filename), "content\n")
      System.cmd("git", ["-C", cwd, "add", "."])
      System.cmd("git", ["-C", cwd, "commit", "-q", "-m", message])
    end

    test "HEAD unmoved: raises-shaped error, no commit landed this cycle", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")

      before = Loop.git_head(ctx.tmp)

      assert {:error, reason} = Loop.verify_commit_landed(before, ctx.tmp)
      assert reason =~ "HEAD did not advance"
    end

    test "HEAD advanced (non-orphaning): passes", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")

      before = Loop.git_head(ctx.tmp)

      commit!(ctx.tmp, "b.txt", "second")

      assert {:ok, after_sha} = Loop.verify_commit_landed(before, ctx.tmp)
      assert is_binary(after_sha)
    end

    test "orphaning HEAD (history rewritten, not extended): raises-shaped error", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")
      commit!(ctx.tmp, "b.txt", "second")

      before = Loop.git_head(ctx.tmp)

      # Rewrite history: reset to an orphan commit unrelated to `before`.
      System.cmd("git", ["-C", ctx.tmp, "checkout", "--orphan", "rewritten"])
      File.write!(Path.join(ctx.tmp, "c.txt"), "content\n")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "rewritten history"])

      assert {:error, reason} = Loop.verify_commit_landed(before, ctx.tmp)
      assert reason =~ "not an ancestor"
    end

    test "non-git cwd / unborn HEAD: fails open", ctx do
      before = Loop.git_head(ctx.tmp)

      assert before == :unborn
      assert Loop.verify_commit_landed(before, ctx.tmp) == {:ok, nil}
    end
  end

  describe "run_loop_catching_infra_abort/1 — the sole producer of exit code 3" do
    test "a normal :ok result passes through untouched (no exit, no rescue triggered)" do
      assert Loop.run_loop_catching_infra_abort(fn -> :ok end) == :ok
    end

    test "a normal {:error, reason} result passes through untouched (not converted to infra exit)" do
      assert Loop.run_loop_catching_infra_abort(fn -> {:error, "gate verdict=failed"} end) ==
               {:error, "gate verdict=failed"}
    end

    test "a DIFFERENT raised exception is NOT swallowed — only InfraAbort is caught" do
      assert_raise RuntimeError, "unrelated crash", fn ->
        Loop.run_loop_catching_infra_abort(fn -> raise "unrelated crash" end)
      end
    end
  end
end

defmodule Mix.Tasks.Codegen.LoopShellTest do
  # Mix.shell/1 changes process-global state; keep mailbox assertions serialized.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Codegen.Loop

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "codegen_loop_shell_test_#{:erlang.unique_integer([:positive])}"
      )

    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    building_dir = Path.join([tmp, "codegen", "pitches", "building"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir, building_dir: building_dir}
  end

  test "4: not-found error message contains the resolved absolute path", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    catch_exit(Loop.resolve_pitch("@codegen/pitches/ready/missing.md", ctx.tmp))

    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ Path.expand("codegen/pitches/ready/missing.md", ctx.tmp)
  end

  describe "maybe_ship_pitch/4" do
    test "dirty working tree: retire is UNCONDITIONAL (pitch still ships), exits @dirty_tree_exit_code",
         ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      System.cmd("git", ["init", "-q", ctx.tmp])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.tmp, "config", "commit.gpgsign", "false"])

      gitkeep = Path.join(ctx.tmp, ".gitkeep")
      File.write!(gitkeep, "")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "initial"])

      File.write!(Path.join(ctx.tmp, "stray.txt"), "uncommitted\n")

      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert catch_exit(Loop.maybe_ship_pitch({:file, abs}, ctx.tmp)) == {:shutdown, 4}

      refute File.exists?(abs)
      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.exists?(shipped_path)

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "COMMITTED and RETIRED"
      assert msg =~ "stray.txt"
    end

    test "with before/after shas: records a git note and stamps frontmatter before the move",
         ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      System.cmd("git", ["init", "-q", ctx.tmp])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.tmp, "config", "commit.gpgsign", "false"])

      File.write!(Path.join(ctx.tmp, "a.txt"), "content\n")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "initial"])
      {before_sha, 0} = System.cmd("git", ["-C", ctx.tmp, "rev-parse", "HEAD"])
      before_sha = String.trim(before_sha)

      body = "---\nstatus: ready\n---\n# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "add pitch"])
      {after_sha, 0} = System.cmd("git", ["-C", ctx.tmp, "rev-parse", "HEAD"])
      after_sha = String.trim(after_sha)

      assert catch_exit(Loop.maybe_ship_pitch({:file, abs}, ctx.tmp, before_sha, after_sha)) ==
               {:shutdown, 4}

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      refute File.exists?(abs)
      assert File.exists?(shipped_path)

      shipped_content = File.read!(shipped_path)
      assert shipped_content =~ "shipped_sha: #{after_sha}"
      assert shipped_content =~ "shipped_range: #{before_sha}..#{after_sha}"
    end
  end

  describe "claim_pitch!/2 — possession by rename" do
    test "a second claim on the same slug refuses (ENOENT — already claimed)", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert {:file, _building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)

      assert catch_exit(Loop.claim_pitch!({:file, abs}, ctx.tmp)) == {:shutdown, 2}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "already claimed"
      assert msg =~ "foo"
    end
  end

  describe "claim_pitch!/2 — handoff_receipt: pre-spend backstop" do
    alias CodegenTestHarness.LoopQueue

    test "a pitch with no handoffs: claims normally", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "---\nstatus: SHAPED\nscope: []\n---\n# foo\n")

      assert {:file, _building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)
    end

    test "a pitch with handoffs: [] (empty) claims normally", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "---\nstatus: SHAPED\nscope: []\nhandoffs: []\n---\n# foo\n")

      assert {:file, _building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)
    end

    test "a pitch with a VALID handoff_receipt: claims normally, file leaves ready/", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      slug = "foo"
      abs = Path.join(ctx.ready_dir, "#{slug}.md")
      record = %{delta_id: "d", source: slug, owner: "other", path: "lib/x.ex"}
      receipt = LoopQueue.handoff_receipt(slug, [record])

      File.write!(
        abs,
        "---\nstatus: SHAPED\nscope: []\nhandoffs: [d::foo::other::lib/x.ex]\nhandoff_receipt: #{receipt}\n---\n# foo\n"
      )

      assert {:file, building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)
      refute File.exists?(abs)
      assert File.exists?(building_abs)
    end

    test "a pitch with an ABSENT handoff_receipt: refuses, exit 2, file stays in ready/", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      abs = Path.join(ctx.ready_dir, "foo.md")

      File.write!(
        abs,
        "---\nstatus: SHAPED\nscope: []\nhandoffs: [d::foo::other::lib/x.ex]\n---\n# foo\n"
      )

      assert catch_exit(Loop.claim_pitch!({:file, abs}, ctx.tmp)) == {:shutdown, 2}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "foo"
      assert msg =~ "handoff_receipt"
      assert File.exists?(abs)
    end

    test "a pitch with a STALE handoff_receipt: (records changed since stamp) refuses", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      slug = "foo"
      abs = Path.join(ctx.ready_dir, "#{slug}.md")

      old_receipt =
        LoopQueue.handoff_receipt(slug, [
          %{delta_id: "d", source: slug, owner: "other", path: "lib/x.ex"}
        ])

      # Record on disk now names a DIFFERENT path than the one the receipt
      # was computed over — the receipt is stale.
      File.write!(
        abs,
        "---\nstatus: SHAPED\nscope: []\nhandoffs: [d::foo::other::lib/y.ex]\nhandoff_receipt: #{old_receipt}\n---\n# foo\n"
      )

      assert catch_exit(Loop.claim_pitch!({:file, abs}, ctx.tmp)) == {:shutdown, 2}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "handoff_receipt"
      assert File.exists?(abs)
    end

    test "a pitch with a MALFORMED handoff_receipt: refuses", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      abs = Path.join(ctx.ready_dir, "foo.md")

      File.write!(
        abs,
        "---\nstatus: SHAPED\nscope: []\nhandoffs: [d::foo::other::lib/x.ex]\nhandoff_receipt: not-a-receipt\n---\n# foo\n"
      )

      assert catch_exit(Loop.claim_pitch!({:file, abs}, ctx.tmp)) == {:shutdown, 2}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "handoff_receipt"
      assert File.exists?(abs)
    end

    test "a pitch with an ORPHAN receipt (receipt present, no handoffs:) is impossible to " <>
           "misclaim — no handoffs: means the receipt is simply never checked",
         ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")

      File.write!(
        abs,
        "---\nstatus: SHAPED\nscope: []\nhandoff_receipt: sha256:#{String.duplicate("0", 64)}\n---\n# foo\n"
      )

      assert {:file, _building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)
    end
  end

  describe "producer (stamp) -> consumer (claim) composition" do
    alias CodegenTestHarness.LoopQueue
    alias Mix.Tasks.Codegen.Pitches.Scope

    test "a receipt stamped by the real Scope task reaches building/ via the real claim path",
         ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      draft_dir = Path.join([ctx.tmp, "codegen", "pitches", "draft"])
      File.mkdir_p!(draft_dir)

      record = "d1::source-a::owner-b::lib/x.ex"
      source_path = Path.join(draft_dir, "source-a.md")
      owner_path = Path.join(draft_dir, "owner-b.md")

      File.write!(
        source_path,
        "---\nstatus: SHAPING\nscope: []\nhandoffs: [#{record}]\n---\n# a\n"
      )

      File.write!(
        owner_path,
        "---\nstatus: SHAPING\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        Scope.run([
          "--cwd=#{ctx.tmp}",
          "--check",
          "--dir=draft",
          "--slug=source-a",
          "--stamp-handoff-receipt"
        ])
      end)

      # Model producer -> consumer: promote source-a to ready/, remove the
      # peer entirely (fleet transfer moves one pitch), then run the real
      # claim path.
      promoted_path = Path.join(ctx.ready_dir, "source-a.md")
      File.rename!(source_path, promoted_path)
      File.rm!(owner_path)

      assert {:ok, [_]} = LoopQueue.parse_handoffs("source-a", promoted_path)

      assert {:file, building_abs} = Loop.claim_pitch!({:file, promoted_path}, ctx.tmp)
      refute File.exists?(promoted_path)
      assert File.exists?(building_abs)
    end
  end

  describe "run_loop_catching_infra_abort/1 — the sole producer of exit code 3" do
    test "OrchestrationLoop.run raising InfraAbort exits {:shutdown, 3} naming the fault" do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      raising_run_fn = fn ->
        raise CodegenTestHarness.InfraAbort, "gate: poisoned DB state no edit can fix"
      end

      assert catch_exit(Loop.run_loop_catching_infra_abort(raising_run_fn)) == {:shutdown, 3}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "poisoned DB state no edit can fix"
    end
  end

  describe "route_reconcile_result/3 — startup recovery routing" do
    test "1: {:ok, :none} runs the ordinary claim+run path" do
      {:ok, ref} = Agent.start_link(fn -> false end)
      run_fn = fn -> Agent.update(ref, fn _ -> true end) end

      assert Loop.route_reconcile_result({:ok, :none}, "requested", run_fn) == :ok
      assert Agent.get(ref, & &1)
    end

    test "2: {:ok, {:resume, slug}} proceeds when requested pitch matches slug" do
      {:ok, ref} = Agent.start_link(fn -> false end)
      run_fn = fn -> Agent.update(ref, fn _ -> true end) end

      assert Loop.route_reconcile_result({:ok, {:resume, "stranded"}}, "stranded", run_fn) == :ok
      assert Agent.get(ref, & &1)
    end

    test "3: {:ok, {:resume, other}} — a DIFFERENT stranded slug earns no veto, requested slug proceeds" do
      # See pitch "restarted builds resume owned work": reconcile/1's result
      # is cleanup/information only. A stranded slug's own resumability is
      # not this invocation's concern — the operator's requested slug always
      # proceeds, dormant recovery never reorders/blocks selection.
      {:ok, ref} = Agent.start_link(fn -> false end)
      run_fn = fn -> Agent.update(ref, fn _ -> true end) end

      assert Loop.route_reconcile_result({:ok, {:resume, "stranded"}}, "requested", run_fn) == :ok
      assert Agent.get(ref, & &1)
    end

    test "3b: {:ok, {:resume, other}} with a literal (nil) requested slug also proceeds" do
      {:ok, ref} = Agent.start_link(fn -> false end)
      run_fn = fn -> Agent.update(ref, fn _ -> true end) end

      assert Loop.route_reconcile_result({:ok, {:resume, "stranded"}}, nil, run_fn) == :ok
      assert Agent.get(ref, & &1)
    end

    test "4: {:ok, {:requeued, slug, recovery}} runs the ordinary claim+run path" do
      {:ok, ref} = Agent.start_link(fn -> false end)
      run_fn = fn -> Agent.update(ref, fn _ -> true end) end

      assert Loop.route_reconcile_result(
               {:ok, {:requeued, "stranded", :clean}},
               "requested",
               run_fn
             ) == :ok

      assert Agent.get(ref, & &1)
    end

    test "5: {:error, reason} halts before claim, spawning no role" do
      run_fn = fn -> flunk("run_fn must not be called") end

      assert Loop.route_reconcile_result({:error, "boom"}, "requested", run_fn) ==
               {:error, "boom"}
    end
  end

  describe "materialize_recovery/4 — same-slug adoption before claim" do
    test "literal source: no-op, never touches recovery" do
      assert Loop.materialize_recovery(:literal, "/irrelevant", "slug", "phoenix") == {nil, nil}
    end

    test "no active dossier: {nil, nil}, byte-for-byte today's behavior", %{tmp: tmp} do
      assert Loop.materialize_recovery({:file, "/abs/probe.md"}, tmp, "probe", "phoenix") ==
               {nil, nil}
    end

    test "an active dossier materializes and resolves the resume role (phoenix)", %{tmp: tmp} do
      init_repo!(tmp)
      File.write!(Path.join(tmp, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(tmp, "probe", "tracked.txt")
      File.write!(Path.join(tmp, "tracked.txt"), "base\n")
      commit!(tmp, "base")
      File.write!(Path.join(tmp, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               CodegenTestHarness.InterruptedCycleRecovery.park_failure(
                 cwd: tmp,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert {:exact, role} =
               Loop.materialize_recovery({:file, pitch_path}, tmp, "probe", "phoenix")

      # No cycle_state was recorded (park happened outside a graded cycle) —
      # exact-base with no cycle_state resolves to the developer role, the
      # recovered bytes' own already-done work, re-entered for a fresh pass.
      assert role == "developer-phoenix-backend"
      assert File.read!(Path.join(tmp, "tracked.txt")) == "changed\n"
    end

    test "a materialization error exits {:shutdown, 1} — never proceeds pretending nothing happened",
         %{tmp: tmp} do
      Mix.shell(Mix.Shell.Process)
      init_repo!(tmp)
      File.write!(Path.join(tmp, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(tmp, "probe", "tracked.txt")
      File.write!(Path.join(tmp, "tracked.txt"), "base\n")
      commit!(tmp, "base")
      File.write!(Path.join(tmp, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               CodegenTestHarness.InterruptedCycleRecovery.park_failure(
                 cwd: tmp,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      # Advance HEAD past the recovery's own source base with a CONFLICTING
      # edit to the same file — apply must refuse.
      File.write!(Path.join(tmp, "tracked.txt"), "conflict\n")
      commit!(tmp, "conflict")

      assert catch_exit(Loop.materialize_recovery({:file, pitch_path}, tmp, "probe", "phoenix")) ==
               {:shutdown, 1}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "FAILED"
    end
  end

  describe "park_and_restore_claim/5 — defect #6: restore_claim always runs" do
    test "literal source: restores nothing (no-op), never calls park_failure" do
      assert Loop.park_and_restore_claim(:literal, "pitch", "/irrelevant", "slug", "boom") == :ok
    end

    test "a file source parks the dirty tree AND restores the claim to ready/", %{
      tmp: tmp,
      ready_dir: ready_dir,
      building_dir: building_dir
    } do
      init_repo!(tmp)
      File.mkdir_p!(building_dir)
      File.write!(Path.join(tmp, ".gitignore"), "codegen/\n")
      claimed = Path.join(building_dir, "probe.md")
      File.write!(claimed, "---\nscope: [tracked.txt]\n---\n# probe\n")
      File.write!(Path.join(tmp, "tracked.txt"), "base\n")
      commit!(tmp, "base")
      File.write!(Path.join(tmp, "tracked.txt"), "dirty from a failed cycle\n")

      assert :ok = Loop.park_and_restore_claim({:file, claimed}, "pitch", tmp, "probe", "boom")

      refute File.exists?(claimed)
      assert File.exists?(Path.join(ready_dir, "probe.md"))
      assert {"", 0} = System.cmd("git", ["-C", tmp, "status", "--porcelain"])

      assert {:ok, dossier} =
               CodegenTestHarness.InterruptedCycleRecovery.active_dossier(tmp, "probe")

      assert dossier["stage"] == "ready"
    end

    test "restore_claim runs even when park_failure itself fails (non-blocking observability)",
         %{tmp: tmp, ready_dir: ready_dir, building_dir: building_dir} do
      # A NON-git cwd makes every park_failure git shell-out fail — the
      # claim must still return to ready/ (pitch "restarted builds resume
      # owned work" defect #6: park failure is non-blocking observability
      # on the pitch's own posture and must never strand it outside ready/).
      File.mkdir_p!(building_dir)
      claimed = Path.join(building_dir, "probe.md")
      File.write!(claimed, "---\nscope: [tracked.txt]\n---\n# probe\n")

      assert :ok = Loop.park_and_restore_claim({:file, claimed}, "pitch", tmp, "probe", "boom")

      refute File.exists?(claimed)
      assert File.exists?(Path.join(ready_dir, "probe.md"))
    end
  end

  defp seeded_pitch!(cwd, slug, scope) do
    path = Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nscope: [#{scope}]\n---\n# #{slug}\n")
    path
  end

  defp init_repo!(cwd) do
    File.mkdir_p!(cwd)
    assert {_, 0} = System.cmd("git", ["-C", cwd, "init", "-q"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "config", "user.email", "test@example.com"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "config", "user.name", "test"])
  end

  defp commit!(cwd, subject) do
    assert {_, 0} = System.cmd("git", ["-C", cwd, "add", "-A"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "commit", "-qm", subject])
  end
end

# System.put_env/2 and System.delete_env/1 are process-global — this module
# stays async: false and lives beside CodegenLoopTest (rather than inside it)
# so its env mutation can never race that module's async: true tests.
defmodule Mix.Tasks.Codegen.LoopBuildResultTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Codegen.Loop

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "codegen_loop_build_result_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "write_build_result!/3" do
    test "with CODEGEN_BUILD_INVOCATION_ID set, writes all five fields", %{tmp: tmp} do
      System.put_env("CODEGEN_BUILD_INVOCATION_ID", "codegen-loop-test-invocation")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_INVOCATION_ID") end)

      result_path = Path.join([tmp, "codegen", "gate-pending", "build-result.json"])

      assert Loop.write_build_result!(tmp, "stranded", "deadbeef") == :ok
      assert File.exists?(result_path)

      payload = result_path |> File.read!() |> Jason.decode!()

      assert payload["invocation_id"] == "codegen-loop-test-invocation"
      assert payload["slug"] == "stranded"
      assert payload["status"] == "success"
      assert payload["head"] == "deadbeef"
      assert is_binary(payload["updated_at"]) and payload["updated_at"] != ""
    end

    test "with the var absent, writes nothing", %{tmp: tmp} do
      System.delete_env("CODEGEN_BUILD_INVOCATION_ID")

      result_path = Path.join([tmp, "codegen", "gate-pending", "build-result.json"])

      assert Loop.write_build_result!(tmp, "stranded", "deadbeef") == :ok
      refute File.exists?(result_path)
    end
  end
end
