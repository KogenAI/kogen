defmodule CodegenTestHarness.LoopGateTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.{LoopGate, LoopQueueDrain}

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_gate_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Writes a per-app `.claude/gate-config.sh` with the given GATE_COMMAND so
  # `decide_gate`/`run_gate` resolve explicitly instead of raising unresolved.
  defp write_gate_config!(dir, gate_command) do
    claude_dir = Path.join(dir, ".claude")
    File.mkdir_p!(claude_dir)
    File.write!(Path.join(claude_dir, "gate-config.sh"), ~s(GATE_COMMAND="#{gate_command}"\n))
  end

  describe "decide_gate/2" do
    test "no step_log, no project config → raises unresolved (fail loud)", %{dir: dir} do
      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "no step_log, mix.exs present but no gate-config → still raises unresolved", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "mix.exs"), "")

      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "no step_log, GATE_COMMAND from per-app config resolves", %{dir: dir} do
      write_gate_config!(dir, "make ci")

      assert LoopGate.decide_gate(dir) == {"make ci", "short", 900}
    end

    test "planner gate-json block in step log wins", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      plan_body = """
      ## Plan

      **Gate**:

      ```gate-json
      {"command": "make custom-gate", "mode": "short", "timeout": 42}
      ```
      """

      File.write!(
        step_log,
        Jason.encode!(%{"ev" => "role", "role" => "planner-phoenix", "body" => plan_body}) <> "\n"
      )

      assert LoopGate.decide_gate(dir, step_log) == {"make custom-gate", "short", 42}
    end

    test "planner gate wins over per-app GATE_COMMAND", %{dir: dir} do
      write_gate_config!(dir, "make ci")

      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      plan_body = """
      ## Plan

      **Gate**: `make custom-gate`
      """

      File.write!(
        step_log,
        Jason.encode!(%{"ev" => "role", "role" => "planner-phoenix", "body" => plan_body}) <> "\n"
      )

      assert {"make custom-gate", _mode, _timeout} = LoopGate.decide_gate(dir, step_log)
    end

    test "raises when gate_select_decide returns a parse-error sentinel (crash loud)", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      plan_body = """
      ## Plan

      **Gate**:

      ```gate-json
      {"command": "make x"
      ```
      """

      File.write!(
        step_log,
        Jason.encode!(%{"ev" => "role", "role" => "planner-phoenix", "body" => plan_body}) <> "\n"
      )

      assert_raise RuntimeError, ~r/gate_select_decide returned a parse error/, fn ->
        LoopGate.decide_gate(dir, step_log)
      end
    end
  end

  describe "planner_body/1" do
    test "nil log_file returns empty string, never raises" do
      assert LoopGate.planner_body(nil) == ""
    end

    test "missing log file on disk returns empty string" do
      assert LoopGate.planner_body("/tmp/does-not-exist-loop-gate-test.jsonl") == ""
    end

    test "extracts a single planner role body verbatim", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      body = "## Plan\n\n**Approach**: do the thing.\n"

      File.write!(
        step_log,
        Jason.encode!(%{"ev" => "role", "role" => "planner-phoenix", "body" => body}) <> "\n"
      )

      assert LoopGate.planner_body(step_log) == body <> "\n"
    end

    test "concatenates multiple planner role events (re-runs) in call order, newline-joined", %{
      dir: dir
    } do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "role", "role" => "planner-phoenix", "body" => "## Plan\n\nplan A"},
          %{"ev" => "role", "role" => "planner-phoenix", "body" => "## Plan\n\nplan B"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.planner_body(step_log) == "## Plan\n\nplan A\n## Plan\n\nplan B\n"
    end

    test "ignores non-planner role events and non-role events", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "init", "pitch" => "x"},
          %{"ev" => "role", "role" => "developer-phoenix-backend", "body" => "dev work"},
          %{"ev" => "role", "role" => "planner-phoenix", "body" => "## Plan\n\nthe plan"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.planner_body(step_log) == "## Plan\n\nthe plan\n"
    end

    test "log with no planner role event returns empty string", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      File.write!(
        step_log,
        Jason.encode!(%{"ev" => "init", "pitch" => "x"}) <> "\n"
      )

      assert LoopGate.planner_body(step_log) == ""
    end
  end

  describe "run_gate/2" do
    test "clear verdict on exit 0, non-static stack (no render check)", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert File.exists?(Path.join(dir, "codegen/gate-pending/gate-result.json"))
    end

    test "failed verdict on non-zero exit", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"boom", 1} end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn)
    end

    test "static stack with no public/ dir skips render check — stays clear", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      assert {:clear, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 preflight_fn: fn _project_dir -> :ok end
               )
    end

    test "static stack with public/ dir invokes render check — PASS stays clear", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end
      render_check_fn = fn _project_dir -> {"RENDER_VERDICT=PASS", 0} end

      assert {:clear, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn,
                 preflight_fn: fn _project_dir -> :ok end
               )
    end

    test "static stack render check FAIL → gate verdict failed", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end
      render_check_fn = fn _project_dir -> {"RENDER_VERDICT=FAIL:no-dom", 0} end

      assert {:failed, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn,
                 preflight_fn: fn _project_dir -> :ok end
               )
    end

    test "static stack render check INCONCLUSIVE collapses to failed (fail-closed)", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      render_check_fn = fn _project_dir ->
        {"RENDER_VERDICT=INCONCLUSIVE:chromium-launch-failed", 0}
      end

      assert {:failed, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn,
                 preflight_fn: fn _project_dir -> :ok end
               )
    end

    test "static stack: gate command itself failing skips render check entirely", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"build broke", 1} end

      render_check_fn = fn _project_dir ->
        flunk("render check must not run when the gate command itself failed")
      end

      assert {:failed, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn,
                 preflight_fn: fn _project_dir -> :ok end
               )
    end
  end

  describe "static render-check dependency preflight" do
    test "missing chromium raises naming the dep (via injected preflight_fn)", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      preflight_fn = fn _project_dir ->
        raise "LoopGate: chromium binary not found — run: npx playwright install chromium"
      end

      assert_raise RuntimeError, ~r/chromium binary not found/, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", preflight_fn: preflight_fn)
      end
    end

    test "phoenix stack does not run preflight", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      preflight_fn = fn _project_dir -> raise "should not run" end

      assert {:clear, "make test"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "phoenix",
                 preflight_fn: preflight_fn
               )
    end

    test "real static preflight passes on a healthy box (chromium present)", %{dir: dir} do
      write_gate_config!(dir, "make ci")
      run_fn = fn _gate, _project_dir -> {"ok", 0} end

      assert {:clear, "make ci"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "static")
    end
  end

  describe "read_verdict/1" do
    test "raises when gate-result.json is absent (never silently treat missing as clear)", %{
      dir: dir
    } do
      assert_raise RuntimeError, ~r/unrecognized\/missing verdict/, fn ->
        LoopGate.read_verdict(dir)
      end
    end
  end

  describe "run_gate/2 — cycle-log verdict recording" do
    defp fresh_cycle_log! do
      path =
        Path.join(
          System.tmp_dir!(),
          "loop_gate_cyclelog_#{:erlang.unique_integer([:positive])}_cycle.jsonl"
        )

      File.write!(path, Jason.encode!(%{"ev" => "init", "pitch" => "x"}) <> "\n")
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp read_gate_events(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["ev"] == "gate"))
    end

    test "nil :cycle_log (no log initialized) → no-op, verdict unaffected", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      calls = :counters.new(1, [])

      log_verdict_fn = fn _cycle_log, _gate, _mode, _marker ->
        :counters.add(calls, 1, 1)
        :ok
      end

      assert {:clear, "make test"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "phoenix",
                 log_verdict_fn: log_verdict_fn
               )

      assert :counters.get(calls, 1) == 1
    end

    test "clear verdict → codegen-log verdict called with the ALL CLEAR marker", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      log_path = fresh_cycle_log!()

      assert {:clear, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", cycle_log: log_path)

      [event] = read_gate_events(log_path)
      assert event["verdict"] == "clear"
      assert event["result"] =~ "ALL CLEAR"
    end

    test "failed verdict → codegen-log verdict called with the FAILED marker", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"boom", 1} end
      log_path = fresh_cycle_log!()

      assert {:failed, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", cycle_log: log_path)

      [event] = read_gate_events(log_path)
      assert event["verdict"] == "failed"
      assert event["result"] =~ "FAILED"
    end

    # LOAD-BEARING: read_verdict/1 collapses "inconclusive" to :failed (the
    # loop's own verdict is binary). Proves the cycle-log event still
    # preserves "inconclusive" distinctly — via verdict_marker, not the atom
    # — even though run_gate/2 itself returns :failed here.
    test "inconclusive render-check verdict is preserved as INCONCLUSIVE in the cycle log, while run_gate/2 returns :failed",
         %{dir: dir} do
      write_gate_config!(dir, "make ci")
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      render_check_fn = fn _project_dir ->
        {"RENDER_VERDICT=INCONCLUSIVE:chromium-launch-failed", 0}
      end

      log_path = fresh_cycle_log!()

      assert {:failed, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn,
                 preflight_fn: fn _project_dir -> :ok end,
                 cycle_log: log_path
               )

      [event] = read_gate_events(log_path)
      assert event["verdict"] == "inconclusive"
      assert event["result"] =~ "INCONCLUSIVE"
    end

    # Fail-open proof: a nonexistent/invalid cycle_log makes the real
    # codegen-log binary exit non-zero; run_gate/2 must still return the
    # correct verdict and must not raise.
    test "codegen-log exit failure (nonexistent cycle_log path) is fail-loud-non-blocking — verdict still correct, no raise",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      bogus_log =
        Path.join(
          System.tmp_dir!(),
          "does_not_exist_#{:erlang.unique_integer([:positive])}.jsonl"
        )

      result_ref = :counters.new(1, [])

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          case LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", cycle_log: bogus_log) do
            {:clear, "make test"} -> :counters.add(result_ref, 1, 1)
            other -> flunk("unexpected verdict: #{inspect(other)}")
          end
        end)

      assert :counters.get(result_ref, 1) == 1
      assert stderr =~ "codegen-log verdict failed" or stderr == ""
    end
  end

  describe "gate record freshness (producer/consumer reconciliation)" do
    # This is the test class whose absence let a producer (LoopGate) writing
    # base_sha "" sit under a consumer (LoopQueueDrain) requiring a
    # non-"" prefix-of-head_before for two commits. Runs the REAL producer
    # against a REAL git repo, then asserts the REAL consumer's default
    # readers satisfy the consumer's own freshness predicate.
    test "run_gate/2 in a real git repo writes a base_sha the drain's own readers accept",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "seed\n")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)

      ts_before = System.system_time(:second)

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      sha = LoopQueueDrain.default_gate_base_sha_fn(dir)
      assert sha != ""

      head = LoopQueueDrain.default_git_head_fn(dir)
      assert String.starts_with?(head, sha)

      assert LoopQueueDrain.default_gate_mtime_fn(dir) >= ts_before
    end

    test "run_gate/2 in a non-git dir still writes base_sha \"\" (fail-open)", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert LoopQueueDrain.default_gate_base_sha_fn(dir) == ""
    end
  end

  describe "graded_tree_sha (content binding)" do
    # No `git add`/`git commit` via System.cmd here — those are structurally
    # forbidden for this role in THIS repo's own tree; these tests operate
    # inside a throwaway `%{dir: dir}` fixture repo, which is a genuinely
    # different git work tree than the one the pre-commit-guard hook is
    # protecting, so the same operations used elsewhere in this test file
    # (line ~391) are fine.
    defp gate_result_graded_tree_sha(dir) do
      path = Path.join(dir, "codegen/gate-pending/gate-result.json")
      {:ok, contents} = File.read(path)
      {:ok, %{"graded_tree_sha" => sha}} = Jason.decode(contents)
      sha
    end

    test "dirty tree at gate time → graded_tree_sha != HEAD^{tree}", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "seed\n")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)

      # Dirty the tree AFTER the base commit, BEFORE the gate runs.
      File.write!(Path.join(dir, "README.md"), "seed\nchanged\n")
      File.write!(Path.join(dir, "new_file.txt"), "new\n")

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      graded_sha = gate_result_graded_tree_sha(dir)
      assert graded_sha != ""

      {head_tree, 0} =
        System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: dir, stderr_to_stdout: true)

      refute graded_sha == String.trim(head_tree)
    end

    test "a post-gate revert changes graded_tree_sha vs. the committed tree", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "seed\n")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)

      File.write!(Path.join(dir, "README.md"), "seed\nchanged\n")

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
      graded_sha = gate_result_graded_tree_sha(dir)

      # Simulate the incident: something reverts the working tree back to
      # HEAD after the gate ran, then a commit lands on the reverted tree.
      System.cmd("git", ["checkout", "HEAD", "--", "README.md"], cd: dir)
      System.cmd("git", ["commit", "--allow-empty", "-q", "-m", "reverted"], cd: dir)

      {commit_tree, 0} =
        System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: dir, stderr_to_stdout: true)

      refute graded_sha == String.trim(commit_tree)
    end

    test "clean tree at gate time, no drift → graded_tree_sha equals the eventual commit tree",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      # Mirrors the real repo's own gitignore for /codegen/ (gate-pending
      # output) — otherwise the gate's own writes (gate-result.json,
      # gate-run.log) get swept into "no drift", which they never are in
      # production.
      File.write!(Path.join(dir, ".gitignore"), "/codegen/\n")
      File.write!(Path.join(dir, "README.md"), "seed\n")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)

      File.write!(Path.join(dir, "README.md"), "seed\nchanged\n")

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
      graded_sha = gate_result_graded_tree_sha(dir)

      # Commit exactly what the gate graded — no drift.
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "matches gate"], cd: dir)

      {commit_tree, 0} =
        System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: dir, stderr_to_stdout: true)

      assert graded_sha == String.trim(commit_tree)
    end

    test "non-git dir → graded_tree_sha \"\" (fail-open, same sentinel as base_sha)", %{
      dir: dir
    } do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert gate_result_graded_tree_sha(dir) == ""
    end

    test "it does not mutate the repo's real index (leaves index-only staged changes untouched)",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "seed\n")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)

      # Stage a change in the REAL index before the gate runs.
      File.write!(Path.join(dir, "README.md"), "seed\nstaged\n")
      System.cmd("git", ["add", "README.md"], cd: dir)

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      {status_out, 0} =
        System.cmd("git", ["status", "--porcelain"], cd: dir, stderr_to_stdout: true)

      # The real index still shows README.md staged (M in the index column) —
      # the temp-index computation never touched it.
      assert String.trim(status_out) =~ ~r/^M\s+README\.md/
    end
  end
end

defmodule CodegenTestHarness.LoopGateCodegenRootTest do
  # Proves the compile-time-derived @codegen_root (used as the preflight's
  # candidate-2 repo-root lookup: <codegen_root>/node_modules/playwright)
  # actually resolves to the codegen repo root — not a directory further up
  # the tree. Asserting on run_gate/2 end-to-end cannot isolate candidate 2:
  # this repo's own node_modules/playwright is also reachable via candidate
  # 3 (Node's bare `require("playwright")` ancestor search), so an
  # end-to-end preflight pass says nothing about candidate 2 specifically —
  # even the pre-fix off-by-one (@codegen_root landing one level too high,
  # at harnesses/ instead of the repo root) would pass end-to-end while
  # candidate 2 silently never resolved. Asserting the derived path directly
  # is the only way to pin candidate 2 correct.
  use ExUnit.Case, async: true

  alias CodegenTestHarness.LoopGate

  test "codegen_root/0 resolves to the actual repo root, not one level too high" do
    root = LoopGate.codegen_root()

    assert File.dir?(Path.join(root, "node_modules")),
           "expected #{root}/node_modules to exist — codegen_root landed at #{root}"

    assert File.dir?(Path.join(root, "harnesses")),
           "expected #{root}/harnesses to exist — codegen_root landed at #{root}"

    assert File.dir?(Path.join(root, "node_modules/playwright")),
           "expected #{root}/node_modules/playwright to exist — the exact candidate-2 " <>
             "path the static preflight probes"

    refute File.dir?(Path.join(root, "hooks")),
           "codegen_root should NOT be harnesses/claude — that's the off-by-one bug " <>
             "(3 levels up from render-check.js's lib/ dir instead of 4)"
  end
end

defmodule CodegenTestHarness.LoopGateEnvScrubTest do
  # async: false — mutates process-global env (System.put_env), which would
  # leak into async: true siblings in LoopGateTest. Sibling module isolates it.
  use ExUnit.Case, async: false

  alias CodegenTestHarness.LoopGate

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_gate_scrub_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("CODEGEN_BUILD_TESTPROBE", "1")

    on_exit(fn ->
      System.delete_env("CODEGEN_BUILD_TESTPROBE")
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "default runner scrubs CODEGEN_BUILD_* from the gate subprocess", %{dir: dir} do
    step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

    plan_body = """
    ## Plan

    **Gate**:

    ```gate-json
    {"command": "env | grep -c '^CODEGEN_BUILD_'", "mode": "short", "timeout": 0}
    ```
    """

    File.write!(
      step_log,
      Jason.encode!(%{"ev" => "role", "role" => "planner-phoenix", "body" => plan_body}) <> "\n"
    )

    # No run_fn override → exercises the REAL default_run_fn/2.
    LoopGate.run_gate(dir, stack: "phoenix", step_log: step_log)

    log = File.read!(Path.join(dir, "codegen/gate-pending/gate-run.log"))

    assert String.trim(log) == "0",
           "expected child to see zero CODEGEN_BUILD_* vars (scrubbed), got: #{inspect(log)}"
  end
end
