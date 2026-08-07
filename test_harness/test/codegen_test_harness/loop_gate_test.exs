defmodule CodegenTestHarness.LoopGateTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.{LoopGate, LoopQueueDrain}

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_gate_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Writes a per-app `.claude/gate-config.sh` with the given GATE_COMMAND (and
  # optional GATE_MODE / GATE_TIMEOUT overrides) so `decide_gate`/`run_gate`
  # resolve explicitly instead of raising unresolved. This config file is now
  # the SOLE gate source — there is no per-cycle override left.
  defp write_gate_config!(dir, gate_command, extra \\ []) do
    claude_dir = Path.join(dir, ".claude")
    File.mkdir_p!(claude_dir)

    body =
      [{"GATE_COMMAND", gate_command} | extra]
      |> Enum.map_join("", fn {key, value} -> ~s(#{key}="#{value}"\n) end)

    File.write!(Path.join(claude_dir, "gate-config.sh"), body)
  end

  describe "decide_gate/1" do
    test "no project config → raises unresolved (fail loud)", %{dir: dir} do
      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "mix.exs present but no gate-config → still raises unresolved", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "mix.exs"), "")

      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "GATE_COMMAND from per-app config resolves", %{dir: dir} do
      write_gate_config!(dir, "make ci")

      assert LoopGate.decide_gate(dir) == {"make ci", "short", 900}
    end

    test "GATE_MODE override wins over the command-derived mode", %{dir: dir} do
      write_gate_config!(dir, "make ci", [{"GATE_MODE", "long"}])

      assert {_gate, "long", _timeout} = LoopGate.decide_gate(dir)
    end

    test "GATE_TIMEOUT override wins over the command-derived timeout", %{dir: dir} do
      write_gate_config!(dir, "make ci", [{"GATE_TIMEOUT", "42"}])

      assert LoopGate.decide_gate(dir) == {"make ci", "short", 42}
    end

    test "a non-numeric GATE_TIMEOUT is a misconfiguration, not a silent fall-back", %{dir: dir} do
      write_gate_config!(dir, "make ci", [{"GATE_TIMEOUT", "soon"}])

      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "an unrecognised GATE_MODE is a misconfiguration, not a silent fall-back", %{dir: dir} do
      write_gate_config!(dir, "make ci", [{"GATE_MODE", "medium"}])

      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end

    test "a cycle log next to the project is NOT a gate source", %{dir: dir} do
      # The retired planner could name a per-cycle gate in the cycle log.
      # Nothing may re-introduce that: with no `.claude/gate-config.sh` the
      # gate is unresolved no matter what the log contains.
      File.write!(
        Path.join(dir, "20260601_120000_test_cycle.jsonl"),
        Jason.encode!(%{
          "ev" => "plan_gate",
          "role" => "developer-phoenix-backend",
          "command" => "make custom-gate",
          "mode" => "short",
          "timeout" => 42
        }) <> "\n"
      )

      assert_raise RuntimeError, ~r/could not resolve a gate/, fn ->
        LoopGate.decide_gate(dir)
      end
    end
  end

  describe "curator_learning_signal/1" do
    test "nil log_file returns :absent, never raises" do
      assert LoopGate.curator_learning_signal(nil) == :absent
    end

    test "missing log file on disk returns :absent" do
      assert LoopGate.curator_learning_signal("/tmp/does-not-exist-loop-gate-test.jsonl") ==
               :absent
    end

    test "log with an ev:learned event returns :learned", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "role", "role" => "developer-phoenix-backend", "body" => "dev work"},
          %{"ev" => "learned", "role" => "developer-phoenix-backend", "text" => "caught a bug"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learning_signal(step_log) == :learned
    end

    test "log with zero ev:learned and >=1 ev:no_learning returns :no_learning", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "role", "role" => "developer-phoenix-backend", "body" => "dev work"},
          %{
            "ev" => "no_learning",
            "role" => "developer-phoenix-backend",
            "text" => "routine fix, nothing durable"
          }
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learning_signal(step_log) == :no_learning
    end

    test "log with BOTH ev:learned and ev:no_learning (mixed cycle) returns :learned", %{
      dir: dir
    } do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "learned", "role" => "developer-phoenix-backend", "text" => "caught a bug"},
          %{"ev" => "no_learning", "role" => "reviewer-phoenix", "text" => "routine review"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learning_signal(step_log) == :learned
    end

    test "log with neither ev:learned nor ev:no_learning (legacy log) returns :absent", %{
      dir: dir
    } do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "init", "pitch" => "x"},
          %{"ev" => "role", "role" => "developer-phoenix-backend", "body" => "dev work"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learning_signal(step_log) == :absent
    end
  end

  describe "curator_learnings/1" do
    test "nil log_file returns {:error, :absent}, never raises" do
      assert LoopGate.curator_learnings(nil) == {:error, :absent}
    end

    test "missing log file on disk returns {:error, :unreadable}" do
      assert LoopGate.curator_learnings("/tmp/does-not-exist-loop-gate-learnings-test.jsonl") ==
               {:error, :unreadable}
    end

    test "log with ev:learned events returns {:ok, [\"role: text\", ...]}", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "role", "role" => "developer-phoenix-backend", "body" => "dev work"},
          %{"ev" => "learned", "role" => "developer-phoenix-backend", "text" => "caught a bug"},
          %{"ev" => "learned", "role" => "reviewer-phoenix", "text" => "scoped a warning"}
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learnings(step_log) ==
               {:ok,
                [
                  "developer-phoenix-backend: caught a bug",
                  "reviewer-phoenix: scoped a warning"
                ]}
    end

    test "log with zero ev:learned events returns {:ok, []} — not an error", %{dir: dir} do
      step_log = Path.join(dir, "20260601_120000_test_cycle.jsonl")

      lines =
        [
          %{"ev" => "init", "pitch" => "x"},
          %{
            "ev" => "no_learning",
            "role" => "developer-phoenix-backend",
            "text" => "routine fix, nothing durable"
          }
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      File.write!(step_log, lines)

      assert LoopGate.curator_learnings(step_log) == {:ok, []}
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

    # Regression for the `1 1` incident: a gate command that exits 0 having
    # run/printed NOTHING must never be scored ALL CLEAR — it is a no-op
    # gate, not a passing one.
    test "exit 0 with a truly empty gate log → failed (no-op gate detector fires)", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"", 0} end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      result =
        Path.join(dir, "codegen/gate-pending/gate-result.json")
        |> File.read!()
        |> Jason.decode!()

      assert result["execution_evidence"] == 0
      assert result["expected_segments"] == 1
    end

    # A chained gate (`make ci && make llm`) has TWO segments — evidence
    # from only one recognized runner footer must still be scored a no-op
    # (the second segment produced no counted evidence).
    test "chained gate command with evidence for only one of two segments → failed", %{dir: dir} do
      write_gate_config!(dir, "make ci && make llm")
      run_fn = fn _gate, _project_dir -> {"519 tests, 0 failures", 0} end

      assert {:failed, "make ci && make llm"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
    end

    test "chained gate command with evidence for both segments → clear", %{dir: dir} do
      write_gate_config!(dir, "make ci && make llm")

      run_fn = fn _gate, _project_dir ->
        {"519 tests, 0 failures\n42 tests, 0 failures", 0}
      end

      assert {:clear, "make ci && make llm"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
    end

    test "static stack with no public/ dir → build produced nothing, verdict failed (no silent PASS)",
         %{dir: dir} do
      write_gate_config!(dir, "make ci")
      run_fn = fn _gate, _project_dir -> {"built ok", 0} end

      assert {:failed, "make ci"} =
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

  describe "run_gate/2 — canary (the gate must prove it can fail)" do
    test "canary returning :clear raises CanaryError and never certifies a verdict", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      canary_fn = fn _gate, _evidence_fn -> :clear end

      assert_raise LoopGate.CanaryError, ~r/the gate cannot fail/, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", canary_fn: canary_fn)
      end

      refute File.exists?(Path.join(dir, "codegen/gate-pending/gate-result.json"))
    end

    test "canary returning :failed (the required answer) lets the real gate proceed", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      canary_fn = fn _gate, _evidence_fn -> :failed end

      assert {:clear, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", canary_fn: canary_fn)
    end

    # This is the fail-closed proof: a STALE prior gate-result.json claiming
    # `clear` must not survive a canary halt. Move A's first act (unlink
    # before anything else can raise) is what makes this true — without it,
    # a halted build would leave the commit step reading yesterday's `clear`.
    test "a stale prior clear gate-result.json does not survive a canary halt", %{dir: dir} do
      write_gate_config!(dir, "make test")
      gate_pending_dir = Path.join(dir, "codegen/gate-pending")
      File.mkdir_p!(gate_pending_dir)

      File.write!(
        Path.join(gate_pending_dir, "gate-result.json"),
        Jason.encode!(%{"verdict" => "clear", "verdict_marker" => "ALL CLEAR ✅"})
      )

      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      canary_fn = fn _gate, _evidence_fn -> :clear end

      assert_raise LoopGate.CanaryError, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", canary_fn: canary_fn)
      end

      refute File.exists?(Path.join(gate_pending_dir, "gate-result.json"))
    end

    test "canary returning :inconclusive also halts — only :failed certifies the gate can fail",
         %{
           dir: dir
         } do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end
      canary_fn = fn _gate, _evidence_fn -> :inconclusive end

      assert_raise LoopGate.CanaryError, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", canary_fn: canary_fn)
      end
    end

    # The real (default) canary, exercised end-to-end against the actual
    # `gate-result.sh` shell contract and the actual `evidence_fn` — no
    # stubbed canary_fn. An empty gate log against any real gate command
    # must always derive :failed; this is the regression test for the `1 1`
    # incident class (constant-evidence disarm AND expected_segments=0
    # disarm) at the level the incident actually happened: production
    # arguments, not hand-picked test operands (ledger #12).
    test "the real default canary derives :failed for a single-segment gate command", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"all good", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
    end

    test "the real default canary derives :failed for a chained multi-segment gate command", %{
      dir: dir
    } do
      write_gate_config!(dir, "make ci && make llm")

      run_fn = fn _gate, _project_dir ->
        {"519 tests, 0 failures\n42 tests, 0 failures", 0}
      end

      assert {:clear, "make ci && make llm"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")
    end

    # Reproduces the historical disarm directly: an evidence_fn hardcoded to
    # `1 1` (the exact incident constants) makes the canary's own
    # empty-log-against-real-command check come back :clear (1 < 1 is
    # false) — proving the canary would have caught the actual incident had
    # it existed at the time.
    test "an evidence_fn hardcoded to the historical `1 1` disarms the canary, which then halts",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"", 0} end
      evidence_fn = fn _gate, _output -> {1, 1} end

      assert_raise LoopGate.CanaryError, fn ->
        LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", evidence_fn: evidence_fn)
      end
    end
  end

  describe "run_gate/2 — witness on an opaque non-zero exit" do
    test "a failed gate log carrying a parseable ExUnit failure location gets a non-empty witness",
         %{dir: dir} do
      write_gate_config!(dir, "make test")

      run_fn = fn _gate, _project_dir ->
        {"  1) test foo (MyTest)\n     test/my_test.exs:42: assert 1 == 2", 1}
      end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      result =
        Path.join(dir, "codegen/gate-pending/gate-result.json")
        |> File.read!()
        |> Jason.decode!()

      assert result["witness"] =~ "test/my_test.exs:42"
    end

    test "a failed gate log with no parseable location gets an empty witness (fail-open)", %{
      dir: dir
    } do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"some opaque failure text", 1} end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      result =
        Path.join(dir, "codegen/gate-pending/gate-result.json")
        |> File.read!()
        |> Jason.decode!()

      assert result["witness"] == ""
    end
  end

  describe "failing_check/1" do
    test "reads the witness the last run_gate/2 call stamped into gate-result.json", %{dir: dir} do
      write_gate_config!(dir, "make test")

      run_fn = fn _gate, _project_dir ->
        {"  1) test foo (MyTest)\n     test/my_test.exs:42: assert 1 == 2", 1}
      end

      assert {:failed, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert LoopGate.failing_check(dir) =~ "test/my_test.exs:42"
    end

    test "empty when gate-result.json is absent (no gate has run yet)", %{dir: dir} do
      assert LoopGate.failing_check(dir) == ""
    end

    test "empty when the last gate was clear (no witness to locate)", %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"1 tests, 0 failures", 0} end

      assert {:clear, "make test"} = LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      assert LoopGate.failing_check(dir) == ""
    end
  end

  describe "run_gate/2 — timeout enforcement" do
    test "a run_fn that never returns within the config-declared deadline yields INCONCLUSIVE (timeout)",
         %{dir: dir} do
      # GATE_TIMEOUT is expressed in whole seconds, so 1 is the smallest usable
      # value here; the run_fn below blocks far longer than 1s.
      write_gate_config!(dir, "make custom-slow-gate", [
        {"GATE_MODE", "short"},
        {"GATE_TIMEOUT", "1"}
      ])

      run_fn = fn _gate, _project_dir ->
        Process.sleep(:infinity)
      end

      assert {:failed, "make custom-slow-gate"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix")

      result =
        Path.join(dir, "codegen/gate-pending/gate-result.json")
        |> File.read!()
        |> Jason.decode!()

      assert result["verdict"] == "inconclusive"
      assert result["verdict_marker"] =~ "INCONCLUSIVE"
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
      File.mkdir_p!(Path.join(dir, "public"))
      run_fn = fn _gate, _project_dir -> {"ok", 0} end
      render_check_fn = fn _project_dir -> {"RENDER_VERDICT=PASS", 0} end

      assert {:clear, "make ci"} =
               LoopGate.run_gate(dir,
                 run_fn: run_fn,
                 stack: "static",
                 render_check_fn: render_check_fn
               )
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

  describe "classify_failure/1" do
    test "defaults to :code for unrecognized text (never silently excuses a real defect)" do
      assert LoopGate.classify_failure("1) test foo\n   assert 1 == 2") == :code
    end

    test "classifies a Postgrex error naming pre-existing DB state as :infra" do
      text = """
      ** (Postgrex.Error) ERROR 42P07 (duplicate_table) relation "users" already exists
          (ecto_sql 3.10.0) lib/ecto/adapters/postgres.ex:100
      """

      assert LoopGate.classify_failure(text) == :infra
    end

    test "classifies a role-does-not-exist Postgrex error as :infra" do
      text =
        "** (Postgrex.Error) FATAL 28000 (invalid_authorization_specification) role \"app_user\" does not exist"

      assert LoopGate.classify_failure(text) == :infra
    end

    test "classifies gate-result.sh's seed-missing/pool-exhaustion vocabulary as :infra" do
      assert LoopGate.classify_failure("classification=seed-missing:no-fixture") == :infra
      assert LoopGate.classify_failure("classification=pool-exhaustion:db-pool-full") == :infra
    end

    test "a code-level compile error is NOT reclassified as infra" do
      text = "** (CompileError) lib/my_app/foo.ex:12: undefined function bar/0"
      assert LoopGate.classify_failure(text) == :code
    end
  end

  describe "stale_build?/1" do
    test "two distinct unavailable modules -> true (stale build)" do
      text = """
      ** (UndefinedFunctionError) function Foo.bar/1 is undefined (module Foo is not available)
      ** (UndefinedFunctionError) function Baz.qux/2 is undefined (module Baz is not available)
      """

      assert LoopGate.stale_build?(text) == true
    end

    test "a single unavailable module -> false (plausible real deleted-module defect)" do
      text =
        "** (UndefinedFunctionError) function Foo.bar/1 is undefined (module Foo is not available)"

      assert LoopGate.stale_build?(text) == false
    end

    test "a genuine undefined-function typo (module present) -> false" do
      text = "** (UndefinedFunctionError) function Foo.bar/1 is undefined or private"

      assert LoopGate.stale_build?(text) == false
    end

    test "a Postgrex infra log -> false (stays :infra via classify_failure, not stolen)" do
      text = "** (Postgrex.Error) ERROR 42P07 (duplicate_table) relation \"users\" already exists"

      assert LoopGate.stale_build?(text) == false
    end
  end

  describe "infra_abort!/2" do
    test "raises CodegenTestHarness.InfraAbort naming the check and reason" do
      assert_raise CodegenTestHarness.InfraAbort, ~r/gate: poisoned DB state/, fn ->
        LoopGate.infra_abort!("gate", "poisoned DB state")
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

      log_verdict_fn = fn _cycle_log, _gate, _mode, _marker, _detail ->
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
    test "failed verdict with a parseable ExUnit failure → detail carries the located witness, not empty",
         %{dir: dir} do
      write_gate_config!(dir, "make test")

      exunit_output = """
      1) test creates a user (MyApp.AccountsTest)
         test/accounts_test.exs:42
         Assertion failed
         stacktrace:
           test/accounts_test.exs:45: (test)

      1 test, 1 failure
      """

      run_fn = fn _gate, _project_dir -> {exunit_output, 1} end
      log_path = fresh_cycle_log!()

      assert {:failed, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", cycle_log: log_path)

      [event] = read_gate_events(log_path)
      assert event["verdict"] == "failed"
      assert event["detail"] != ""
      assert event["detail"] =~ "test/accounts_test.exs:45"
    end

    test "failed verdict with unparseable gate output → detail records a named sentinel, never empty",
         %{dir: dir} do
      write_gate_config!(dir, "make test")
      run_fn = fn _gate, _project_dir -> {"some coverage noise, no failure lines", 1} end
      log_path = fresh_cycle_log!()

      assert {:failed, "make test"} =
               LoopGate.run_gate(dir, run_fn: run_fn, stack: "phoenix", cycle_log: log_path)

      [event] = read_gate_events(log_path)
      assert event["verdict"] == "failed"
      assert event["detail"] != ""
      assert event["detail"] =~ "no parseable failure location"
    end

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
    claude_dir = Path.join(dir, ".claude")
    File.mkdir_p!(claude_dir)

    File.write!(
      Path.join(claude_dir, "gate-config.sh"),
      ~s(GATE_COMMAND="env | grep -c '^CODEGEN_BUILD_'"\nGATE_MODE="short"\nGATE_TIMEOUT="0"\n)
    )

    # No run_fn override → exercises the REAL default_run_fn/2.
    LoopGate.run_gate(dir, stack: "phoenix")

    log = File.read!(Path.join(dir, "codegen/gate-pending/gate-run.log"))

    assert String.trim(log) == "0",
           "expected child to see zero CODEGEN_BUILD_* vars (scrubbed), got: #{inspect(log)}"
  end
end
