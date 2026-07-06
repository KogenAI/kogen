defmodule CodegenTestHarness.LoopGateTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.LoopGate

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_gate_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "decide_gate/2" do
    test "no step_log, no project config, non-Phoenix dir → make test fallback", %{dir: dir} do
      assert LoopGate.decide_gate(dir) == {"make test", "short", 0}
    end

    test "no step_log, mix.exs present → make ci fallback", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "")

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

  describe "run_gate/2" do
    test "clear verdict on exit 0, non-static stack (no render check)", %{dir: dir} do
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert File.exists?(Path.join(dir, "codegen/gate-pending/gate-result.json"))
    end

    test "failed verdict on non-zero exit", %{dir: dir} do
      run_fn = fn _gate, _project_dir -> {"boom", 1} end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn)
    end

    test "static stack with no public/ dir skips render check — stays clear", %{dir: dir} do
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      # stack_default_gate/2 forces static's stack-blind "make test" fallback
      # to "make ci" (no mix.exs, no step_log -> gate-select's default).
      assert {:clear, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 preflight_fn: fn _project_dir -> :ok end
               )
    end

    test "static stack with public/ dir invokes render check — PASS stays clear", %{dir: dir} do
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
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      preflight_fn = fn _project_dir ->
        raise "LoopGate: chromium binary not found — run: npx playwright install chromium"
      end

      assert_raise RuntimeError, ~r/chromium binary not found/, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", preflight_fn: preflight_fn)
      end
    end

    test "phoenix stack does not run preflight", %{dir: dir} do
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
