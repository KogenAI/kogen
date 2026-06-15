defmodule CodegenTestHarness.BenchTest do
  @moduledoc """
  Unit tests for the bench modules: BenchMetrics, UsageParser, BenchManifest,
  BenchView. No LLM calls — pure logic + filesystem fixtures in tmp dirs.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.BenchManifest
  alias CodegenTestHarness.BenchMetrics
  alias CodegenTestHarness.BenchView
  alias CodegenTestHarness.UsageParser

  # ── BenchMetrics ─────────────────────────────────────────────────────────────

  describe "BenchMetrics" do
    test "all_metrics/0 returns non-empty list" do
      metrics = BenchMetrics.all_metrics()
      assert length(metrics) > 0
    end

    test "every metric has required keys" do
      for metric <- BenchMetrics.all_metrics() do
        assert Map.has_key?(metric, :id)
        assert Map.has_key?(metric, :unit)
        assert Map.has_key?(metric, :source)
        assert Map.has_key?(metric, :aggregator)
        assert Map.has_key?(metric, :gap)
      end
    end

    test "measurable/0 returns only gap-nil entries" do
      measurable = BenchMetrics.measurable()
      assert Enum.all?(measurable, fn m -> is_nil(m.gap) end)
      assert length(measurable) > 0
    end

    test "gaps/0 returns only gap-string entries" do
      gaps = BenchMetrics.gaps()
      assert Enum.all?(gaps, fn m -> is_binary(m.gap) end)
      assert length(gaps) > 0
    end

    test "measurable + gaps = all_metrics" do
      all = BenchMetrics.all_metrics()
      measurable = BenchMetrics.measurable()
      gap_entries = BenchMetrics.gaps()
      assert length(measurable) + length(gap_entries) == length(all)
    end

    test "metric_for/1 returns correct entry" do
      metric = BenchMetrics.metric_for(:cost_usd)
      assert metric.id == :cost_usd
      assert metric.unit == "USD"
      assert is_nil(metric.gap)
    end

    test "metric_for/1 returns nil for unknown id" do
      assert BenchMetrics.metric_for(:nonexistent_metric) == nil
    end

    test "build_duration_ms is a measurable :sum metric" do
      m = BenchMetrics.metric_for(:build_duration_ms)
      assert m != nil
      assert m.aggregator == :sum
      assert m.gap == nil
      assert Enum.any?(BenchMetrics.measurable(), &(&1.id == :build_duration_ms))
    end

    test "stub metrics have gap strings" do
      for id <- [:judge_pass_rate, :lighthouse_score, :judge_coherence_score] do
        metric = BenchMetrics.metric_for(id)
        assert is_binary(metric.gap), "expected gap string for #{id}"
      end
    end

    test "measurable metrics include all expected token fields" do
      measurable_ids = BenchMetrics.measurable() |> Enum.map(& &1.id)

      for id <- [:input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens] do
        assert id in measurable_ids, "expected #{id} in measurable"
      end
    end
  end

  # ── UsageParser — Claude path ─────────────────────────────────────────────────

  describe "UsageParser.parse/2 — :claude" do
    @claude_stream_json """
    {"type":"system","subtype":"init","model":"claude-sonnet-4-6-20250514","apiKeySource":"env"}
    {"type":"assistant","message":{"role":"assistant","content":[]}}
    {"type":"result","subtype":"success","duration_ms":12345,"duration_api_ms":9876,"num_turns":3,"terminal_reason":"max_turns","total_cost_usd":0.012345,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10},"modelUsage":{"claude-sonnet-4-6-20250514":{"inputTokens":100,"outputTokens":50,"cacheReadInputTokens":20,"cacheCreationInputTokens":10,"costUSD":0.012345}}}
    """

    test "extracts model from system/init line" do
      parsed = UsageParser.parse(@claude_stream_json, :claude)
      assert parsed.model == "claude-sonnet-4-6-20250514"
    end

    test "extracts token counts from result line" do
      parsed = UsageParser.parse(@claude_stream_json, :claude)
      assert parsed.input_tokens == 100
      assert parsed.output_tokens == 50
      assert parsed.cache_read_tokens == 20
      assert parsed.cache_creation_tokens == 10
    end

    test "extracts cost and timing" do
      parsed = UsageParser.parse(@claude_stream_json, :claude)
      assert_in_delta parsed.cost_usd, 0.012345, 0.000001
      assert parsed.duration_ms == 12_345
      assert parsed.duration_api_ms == 9_876
      assert parsed.num_turns == 3
    end

    test "extracts terminal_reason" do
      parsed = UsageParser.parse(@claude_stream_json, :claude)
      assert parsed.terminal_reason == "max_turns"
    end

    test "returns :unknown for missing fields on empty input" do
      parsed = UsageParser.parse("", :claude)
      assert parsed.model == :unknown
      assert parsed.input_tokens == :unknown
      assert parsed.cost_usd == :unknown
    end

    test "tolerates non-json lines gracefully" do
      mixed = "not json at all\n" <> @claude_stream_json
      parsed = UsageParser.parse(mixed, :claude)
      assert parsed.model == "claude-sonnet-4-6-20250514"
    end

    test "picks last result/success line when multiple present" do
      double =
        @claude_stream_json <>
          ~s({"type":"result","subtype":"success","total_cost_usd":0.999,"duration_ms":99,"duration_api_ms":88,"num_turns":9,"terminal_reason":"stop","usage":{"input_tokens":999}}) <>
          "\n"

      parsed = UsageParser.parse(double, :claude)
      assert parsed.num_turns == 9
      assert parsed.input_tokens == 999
    end
  end

  # ── UsageParser — Pi path ─────────────────────────────────────────────────────

  describe "UsageParser.parse/2 — :pi" do
    @pi_agent_end """
    {"type":"session","id":"abc"}
    {"type":"agent_end","messages":[{"role":"assistant","model":"gpt-5.4-mini","usage":{"input":100,"output":18,"cacheRead":0,"cacheWrite":0,"totalTokens":118,"cost":{"input":0.004083,"output":0.000081,"cacheRead":0,"cacheWrite":0,"total":0.004164}}}],"willRetry":false}
    """

    test "extracts model from agent_end messages" do
      parsed = UsageParser.parse(@pi_agent_end, :pi)
      assert parsed.model == "gpt-5.4-mini"
    end

    test "extracts token counts from pi usage fields" do
      parsed = UsageParser.parse(@pi_agent_end, :pi)
      assert parsed.input_tokens == 100
      assert parsed.output_tokens == 18
      assert parsed.cache_read_tokens == 0
      assert parsed.cache_creation_tokens == 0
    end

    test "extracts cost from pi cost.total" do
      parsed = UsageParser.parse(@pi_agent_end, :pi)
      assert_in_delta parsed.cost_usd, 0.004164, 0.000001
    end

    test "duration and turn fields are :unknown for pi" do
      parsed = UsageParser.parse(@pi_agent_end, :pi)
      assert parsed.duration_ms == :unknown
      assert parsed.duration_api_ms == :unknown
      assert parsed.num_turns == :unknown
      assert parsed.terminal_reason == :unknown
    end

    test "returns :unknown map when no agent_end present" do
      parsed = UsageParser.parse(~s({"type":"session"}), :pi)
      assert parsed.model == :unknown
      assert parsed.input_tokens == :unknown
    end

    # #8 — pi multi-message accumulation
    test "accumulates tokens across multiple messages in agent_end" do
      jsonl =
        ~s({"type":"agent_end","messages":[{"role":"assistant","model":"gpt-5.4-mini","usage":{"input":100,"output":10,"cacheRead":5,"cacheWrite":2,"cost":{"total":0.001}}},{"role":"assistant","model":"gpt-5.4-mini","usage":{"input":200,"output":20,"cacheRead":3,"cacheWrite":1,"cost":{"total":0.002}}}]}) <>
          "\n"

      parsed = UsageParser.parse(jsonl, :pi)
      assert parsed.model == "gpt-5.4-mini"
      assert parsed.input_tokens == 300
      assert parsed.output_tokens == 30
      assert parsed.cache_read_tokens == 8
      assert parsed.cache_creation_tokens == 3
      assert_in_delta parsed.cost_usd, 0.003, 0.000001
    end

    # #9 — pi agent_end without messages key
    test "returns :unknown for all fields when agent_end has no messages key" do
      jsonl = ~s({"type":"agent_end"})
      parsed = UsageParser.parse(jsonl, :pi)
      assert parsed.model == :unknown
      assert parsed.input_tokens == :unknown
      assert parsed.output_tokens == :unknown
      assert parsed.cost_usd == :unknown
    end

    # #10 — pi partial usage (missing fields)
    test "returns :unknown for missing usage fields in pi message" do
      jsonl = ~s({"type":"agent_end","messages":[{"role":"assistant","model":"gpt-x"}]})
      parsed = UsageParser.parse(jsonl, :pi)
      assert parsed.model == "gpt-x"
      assert parsed.input_tokens == :unknown
      assert parsed.output_tokens == :unknown
      assert parsed.cache_read_tokens == :unknown
      assert parsed.cost_usd == :unknown
    end

    test "partial usage: message with usage but no cost field" do
      jsonl =
        ~s({"type":"agent_end","messages":[{"model":"gpt-x","usage":{"input":50,"output":5}}]})

      parsed = UsageParser.parse(jsonl, :pi)
      assert parsed.input_tokens == 50
      assert parsed.output_tokens == 5
      assert parsed.cost_usd == :unknown
    end
  end

  # ── BenchManifest ─────────────────────────────────────────────────────────────

  describe "BenchManifest" do
    setup do
      run_dir = Path.join(System.tmp_dir!(), "bench_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(run_dir)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(run_dir) end)
      {:ok, run_dir: run_dir}
    end

    defp write_skeleton(run_dir) do
      manifest = %{
        "codegen_sha" => "abc123",
        "harness_versions" => %{"claude" => "2.1.153", "pi" => "0.76.0"},
        "started_at" => "2026-05-28T07:00:00Z",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
      File.write!(Path.join(run_dir, "reason.txt"), "test reason")
    end

    test "record_resolution/4 writes model id", %{run_dir: run_dir} do
      write_skeleton(run_dir)
      BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-haiku")
      manifest = BenchManifest.load(run_dir)
      assert manifest["model_resolution"]["claude/app_build"] == "claude-haiku"
    end

    test "record_resolution/4 is idempotent for same value", %{run_dir: run_dir} do
      write_skeleton(run_dir)
      BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-haiku")
      BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-haiku")
      manifest = BenchManifest.load(run_dir)
      assert manifest["model_resolution"]["claude/app_build"] == "claude-haiku"
    end

    test "record_resolution/4 raises on conflict", %{run_dir: run_dir} do
      write_skeleton(run_dir)
      BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-haiku")

      assert_raise RuntimeError, ~r/conflict/, fn ->
        BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-sonnet")
      end
    end

    test "record_resolution/4 supports multiple harness/role keys", %{run_dir: run_dir} do
      write_skeleton(run_dir)
      BenchManifest.record_resolution(run_dir, "claude", "app_build", "claude-haiku")
      BenchManifest.record_resolution(run_dir, "pi", "app_build", "gpt-5.4-mini")
      manifest = BenchManifest.load(run_dir)
      assert manifest["model_resolution"]["claude/app_build"] == "claude-haiku"
      assert manifest["model_resolution"]["pi/app_build"] == "gpt-5.4-mini"
    end

    test "load/1 decodes manifest json", %{run_dir: run_dir} do
      write_skeleton(run_dir)
      manifest = BenchManifest.load(run_dir)
      assert manifest["codegen_sha"] == "abc123"
      assert manifest["harness_versions"]["claude"] == "2.1.153"
    end
  end

  # ── BenchView ─────────────────────────────────────────────────────────────────

  describe "BenchView" do
    setup do
      root_dir =
        Path.join(System.tmp_dir!(), "bench_view_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(root_dir)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root_dir) end)
      {:ok, root_dir: root_dir}
    end

    defp create_run(root_dir, ts, opts \\ []) do
      run_dir = Path.join(root_dir, ts)

      File.mkdir_p!(Path.join([run_dir, "runs", "claude", "phoenix"]))
      File.mkdir_p!(Path.join([run_dir, "runs", "pi", "phoenix"]))

      manifest = %{
        "codegen_sha" => "abc123",
        "harness_versions" => %{"claude" => "2.1.153", "pi" => "0.76.0"},
        "started_at" => "2026-05-28T07:00:00Z",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
      File.write!(Path.join(run_dir, "reason.txt"), Keyword.get(opts, :reason, "test run"))

      test_name = Keyword.get(opts, :test_name, "scaffold_test")
      assertion_passed = Keyword.get(opts, :assertion_passed, true)

      summary = %{
        "type" => "harness_summary",
        "test_name" => test_name,
        "exit_code" => 0,
        "assertion_passed" => assertion_passed,
        "parsed" => %{
          "model" => "claude-haiku",
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_tokens" => 20,
          "cache_creation_tokens" => 10,
          "cost_usd" => 0.01,
          "duration_ms" => 5000,
          "duration_api_ms" => 4000,
          "build_duration_ms" => 120000,
          "num_turns" => 3,
          "terminal_reason" => "stop"
        }
      }

      jsonl_path = Path.join([run_dir, "runs", "claude", "phoenix", "#{test_name}.jsonl"])
      File.write!(jsonl_path, Jason.encode!(summary))

      run_dir
    end

    test "list_runs/1 returns runs newest-first", %{root_dir: root_dir} do
      create_run(root_dir, "20260501_120000")
      create_run(root_dir, "20260502_120000")
      create_run(root_dir, "20260503_120000")

      runs = BenchView.list_runs(root_dir)
      assert length(runs) == 3
      paths = Enum.map(runs, & &1.path)
      assert List.first(paths) =~ "20260503"
      assert List.last(paths) =~ "20260501"
    end

    test "list_runs/1 returns empty list for missing dir" do
      assert BenchView.list_runs("/tmp/nonexistent_bench_dir_xyz") == []
    end

    test "list_runs/1 includes pass_rate_per_shape", %{root_dir: root_dir} do
      create_run(root_dir, "20260501_120000", assertion_passed: true)
      [run] = BenchView.list_runs(root_dir)
      assert is_map(run.pass_rate_per_shape)
    end

    test "load_run/1 returns manifest and test records", %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_120000")
      loaded = BenchView.load_run(run_dir)
      assert is_map(loaded.manifest)
      assert is_list(loaded.tests)
      assert length(loaded.tests) == 1
    end

    test "load_run/1 test record has correct fields", %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_120000", test_name: "my_test")
      loaded = BenchView.load_run(run_dir)
      [test] = loaded.tests
      assert test.test_name == "my_test"
      assert test.harness == "claude"
      assert test.stack == "phoenix"
      assert test.exit_code == 0
      assert test.assertion_passed == true
    end

    test "render_table/1 returns iodata string", %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_120000")
      loaded = BenchView.load_run(run_dir)
      table = BenchView.render_table(loaded)
      assert is_binary(table)
      assert String.contains?(table, "cost_usd")
    end

    test "render_table/1 shows (n/a) for :unknown fields", %{root_dir: root_dir} do
      run_dir = Path.join(root_dir, "20260501_130000")
      File.mkdir_p!(Path.join([run_dir, "runs", "claude", "phoenix"]))

      manifest = %{
        "codegen_sha" => "abc",
        "harness_versions" => %{},
        "started_at" => "2026-05-01T13:00:00Z",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(run_dir, "reason.txt"), "test")

      summary = %{
        "type" => "harness_summary",
        "test_name" => "unknown_test",
        "exit_code" => 0,
        "assertion_passed" => true,
        "parsed" => %{
          "model" => ":unknown",
          "input_tokens" => ":unknown",
          "output_tokens" => ":unknown",
          "cache_read_tokens" => ":unknown",
          "cache_creation_tokens" => ":unknown",
          "cost_usd" => ":unknown",
          "duration_ms" => ":unknown",
          "duration_api_ms" => ":unknown",
          "num_turns" => ":unknown",
          "terminal_reason" => ":unknown"
        }
      }

      jsonl_path = Path.join([run_dir, "runs", "claude", "phoenix", "unknown_test.jsonl"])
      File.write!(jsonl_path, Jason.encode!(summary))

      loaded = BenchView.load_run(run_dir)
      table = BenchView.render_table(loaded)
      assert String.contains?(table, "(n/a)")
    end

    test "render_table/1 shows gap strings for stub metrics", %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_140000")
      loaded = BenchView.load_run(run_dir)
      table = BenchView.render_table(loaded)
      assert String.contains?(table, "not measured")
    end

    test "compare/2 produces delta list", %{root_dir: root_dir} do
      run_dir_a = create_run(root_dir, "20260501_120000")
      run_dir_b = create_run(root_dir, "20260502_120000")
      loaded_a = BenchView.load_run(run_dir_a)
      loaded_b = BenchView.load_run(run_dir_b)
      deltas = BenchView.compare(loaded_a, loaded_b)
      assert is_list(deltas)
      assert length(deltas) > 0

      delta = Enum.find(deltas, fn d -> d.metric_id == :cost_usd end)
      assert delta != nil
    end

    test "previous-run auto-pick: list_runs returns correct order for comparison",
         %{root_dir: root_dir} do
      create_run(root_dir, "20260501_120000", reason: "run 1")
      create_run(root_dir, "20260502_120000", reason: "run 2")
      create_run(root_dir, "20260503_120000", reason: "run 3")

      runs = BenchView.list_runs(root_dir)
      [newest | rest] = runs
      assert newest.reason == "run 3"
      assert hd(rest).reason == "run 2"
    end

    # #11 — render_table/2 with non-nil deltas shows delta column
    test "render_table/2 with deltas renders delta column", %{root_dir: root_dir} do
      run_dir_a = create_run(root_dir, "20260501_120000")
      run_dir_b = create_run(root_dir, "20260502_120000")
      loaded_a = BenchView.load_run(run_dir_a)
      loaded_b = BenchView.load_run(run_dir_b)
      deltas = BenchView.compare(loaded_a, loaded_b)
      table = BenchView.render_table(loaded_a, deltas)
      assert is_binary(table)
      # Delta column header present
      assert String.contains?(table, "Delta")
      # cost_usd delta between identical runs = 0.0
      assert String.contains?(table, "+$")
    end

    # #12 — compare/2 delta arithmetic with different cost_usd
    test "compare/2 cost_usd delta is non-zero and correct when runs differ",
         %{root_dir: root_dir} do
      # cost_usd in create_run fixture is 0.01
      run_dir_a = create_run(root_dir, "20260501_120000")

      # Build a second run with different cost (0.05)
      run_dir_b = Path.join(root_dir, "20260502_120000")
      File.mkdir_p!(Path.join([run_dir_b, "runs", "claude", "phoenix"]))
      File.mkdir_p!(Path.join([run_dir_b, "runs", "pi", "phoenix"]))

      manifest = %{
        "codegen_sha" => "def456",
        "harness_versions" => %{"claude" => "2.1.153", "pi" => "0.76.0"},
        "started_at" => "2026-05-02T12:00:00Z",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir_b, "manifest.json"), Jason.encode!(manifest, pretty: true))
      File.write!(Path.join(run_dir_b, "reason.txt"), "run 2")

      summary_b = %{
        "type" => "harness_summary",
        "test_name" => "scaffold_test",
        "exit_code" => 0,
        "assertion_passed" => true,
        "parsed" => %{
          "model" => "claude-haiku",
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_tokens" => 20,
          "cache_creation_tokens" => 10,
          "cost_usd" => 0.05,
          "duration_ms" => 5000,
          "duration_api_ms" => 4000,
          "build_duration_ms" => 95000,
          "num_turns" => 3,
          "terminal_reason" => "stop"
        }
      }

      jsonl_b = Path.join([run_dir_b, "runs", "claude", "phoenix", "scaffold_test.jsonl"])
      File.write!(jsonl_b, Jason.encode!(summary_b))

      loaded_a = BenchView.load_run(run_dir_a)
      loaded_b = BenchView.load_run(run_dir_b)
      deltas = BenchView.compare(loaded_a, loaded_b)

      cost_delta = Enum.find(deltas, fn d -> d.metric_id == :cost_usd end)
      assert cost_delta != nil
      # current (a) = 0.01, previous (b) = 0.05 → diff = 0.01 - 0.05 = -0.04
      assert cost_delta.diff != :not_comparable
      assert_in_delta cost_delta.diff, -0.04, 0.0001
    end

    # previous_run_path/2 auto-pick
    test "previous_run_path/2 finds lex-largest run strictly less than current",
         %{root_dir: root_dir} do
      create_run(root_dir, "20260501_120000")
      create_run(root_dir, "20260502_120000")
      current_dir = Path.join(root_dir, "20260503_120000")
      create_run(root_dir, "20260503_120000")

      prev = BenchView.previous_run_path(root_dir, current_dir)
      assert prev != nil
      assert String.ends_with?(prev, "20260502_120000")
    end

    test "previous_run_path/2 returns nil when no older run exists",
         %{root_dir: root_dir} do
      current_dir = Path.join(root_dir, "20260501_120000")
      create_run(root_dir, "20260501_120000")
      assert BenchView.previous_run_path(root_dir, current_dir) == nil
    end

    # screenshot_path field — additive, no aggregator impact
    test "load_run/1 sets screenshot_path to absolute PNG path when sibling PNG exists",
         %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_120000", test_name: "my_static_test")

      png_path = Path.join([run_dir, "runs", "claude", "phoenix", "my_static_test.png"])
      File.write!(png_path, "fake png bytes")

      loaded = BenchView.load_run(run_dir)
      [test] = loaded.tests
      assert test.screenshot_path == png_path
    end

    test "load_run/1 sets screenshot_path to nil when sibling PNG is absent",
         %{root_dir: root_dir} do
      run_dir = create_run(root_dir, "20260501_120000", test_name: "no_png_test")
      loaded = BenchView.load_run(run_dir)
      [test] = loaded.tests
      assert test.screenshot_path == nil
    end
  end
end
