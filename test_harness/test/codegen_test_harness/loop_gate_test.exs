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
      step_log = Path.join(dir, "session.md")

      File.write!(step_log, """
      ## Plan

      **Gate**:

      ```gate-json
      {"command": "make custom-gate", "mode": "short", "timeout": 42}
      ```
      """)

      assert LoopGate.decide_gate(dir, step_log) == {"make custom-gate", "short", 42}
    end

    test "raises when gate_select_decide returns a parse-error sentinel (crash loud)", %{dir: dir} do
      step_log = Path.join(dir, "session.md")

      File.write!(step_log, """
      ## Plan

      **Gate**:

      ```gate-json
      {"command": "make x"
      ```
      """)

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

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "static")
    end

    test "static stack with public/ dir invokes render check — PASS stays clear", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end
      render_check_fn = fn _project_dir -> {"RENDER_VERDICT=PASS", 0} end

      assert {:clear, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", render_check_fn: render_check_fn)
    end

    test "static stack render check FAIL → gate verdict failed", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end
      render_check_fn = fn _project_dir -> {"RENDER_VERDICT=FAIL:no-dom", 0} end

      assert {:failed, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", render_check_fn: render_check_fn)
    end

    test "static stack render check INCONCLUSIVE → gate verdict inconclusive", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      render_check_fn = fn _project_dir ->
        {"RENDER_VERDICT=INCONCLUSIVE:chromium-launch-failed", 0}
      end

      assert {:inconclusive, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", render_check_fn: render_check_fn)
    end

    test "static stack: gate command itself failing skips render check entirely", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"build broke", 1} end

      render_check_fn = fn _project_dir ->
        flunk("render check must not run when the gate command itself failed")
      end

      assert {:failed, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "static", render_check_fn: render_check_fn)
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
