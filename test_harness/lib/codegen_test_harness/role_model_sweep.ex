defmodule CodegenTestHarness.RoleModelSweep do
  @moduledoc """
  Runs a role-model-binding campaign: holds ONE build role's
  harness/model/effort fixed across a generated baseline arm and one or more
  operator-supplied candidate arms, on ONE live-build workload file, across
  repeated repetitions, and writes objective (pass-rate / cost / duration)
  comparison evidence.

  **KEEP-ADVISORY**: this module produces evidence for a human operator to
  review before separately shaping a `templates/generator/config.yaml`
  binding change. It NEVER edits config.yaml, NEVER selects a "winner", and
  NEVER runs without an operator explicitly invoking
  `mix codegen.bench.role_model_sweep` (paid) or `--validate-only` (free).
  Subjective output quality is not inferred from these metrics — `evidence.md`
  links every artifact and states manual review is required.

  ## Campaign matrix (YAML)

      role: developer-static
      stack: static
      build_harness: claude
      test: test/stacks/static/scaffold_test.exs
      repetitions: 3
      tolerances:
        cost_pct: 0
        duration_pct: 20
      candidates:
        - name: candidate-a
          harness: claude
          model: opus
          effort: high

  ## Binding transport

  For each scheduled arm × repetition, this module writes
  `<repetition_run_dir>/role-model-binding.json` — the loop
  (`OrchestrationLoop.resolve_fixed_binding/2`) reads it from `BENCH_RUN_DIR`
  and pins the target role's binding for that single child `mix test`
  invocation only. See `OrchestrationLoop` moduledoc section "Fixed campaign
  binding" for the read/validate/suppress contract.
  """

  alias CodegenTestHarness.{BenchManifest, BenchView, RoleResolver, UsageParser}

  @codegen_root Path.expand("../../..", __DIR__)
  @valid_stacks ~w(phoenix static)
  @valid_harnesses ~w(claude)
  @valid_efforts ~w(low medium high)
  @min_repetitions 3

  @type candidate :: %{
          name: String.t(),
          harness: String.t(),
          model: String.t(),
          effort: String.t()
        }
  @type matrix :: %{
          role: String.t(),
          stack: String.t(),
          build_harness: String.t(),
          test: String.t(),
          repetitions: pos_integer(),
          tolerances: %{cost_pct: number(), duration_pct: number()},
          candidates: [candidate()]
        }

  # ── Matrix loading + validation ─────────────────────────────────────────

  @doc """
  Loads and validates a campaign matrix YAML file at `path` (resolved
  against `cwd`). Raises `RuntimeError` naming the failing contract on any
  invalid field, missing tool, or unresolvable path — never a silent
  partial matrix.
  """
  @spec load_matrix!(String.t(), String.t()) :: matrix()
  def load_matrix!(path, cwd) do
    abs_path = Path.expand(path, cwd)

    unless File.exists?(abs_path) do
      raise "RoleModelSweep: matrix file not found: #{abs_path}"
    end

    raw = yaml_to_json!(abs_path)

    validate_matrix!(raw)
  end

  defp yaml_to_json!(path) do
    case System.cmd("yq", ["-o=json", ".", path], stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, decoded} ->
            decoded

          {:error, err} ->
            raise "RoleModelSweep: matrix YAML decoded to invalid JSON: #{inspect(err)}"
        end

      {out, code} ->
        raise "RoleModelSweep: yq failed (exit #{code}) parsing #{path}: #{out}"
    end
  end

  @spec validate_matrix!(map()) :: matrix()
  def validate_matrix!(%{} = raw) do
    role = require_string!(raw, "role")
    stack = require_string!(raw, "stack")
    build_harness = require_string!(raw, "build_harness")
    test = require_string!(raw, "test")
    repetitions = require_repetitions!(raw)
    tolerances = require_tolerances!(raw)
    candidates = require_candidates!(raw)

    unless stack in @valid_stacks do
      raise "RoleModelSweep: \"stack\" must be one of #{inspect(@valid_stacks)}, got: #{inspect(stack)}"
    end

    unless build_harness in @valid_harnesses do
      raise "RoleModelSweep: \"build_harness\" must be one of #{inspect(@valid_harnesses)}, got: #{inspect(build_harness)}"
    end

    unless role in CodegenTestHarness.OrchestrationLoop.role_sequence(stack) do
      raise "RoleModelSweep: role #{inspect(role)} is not in the #{stack} role sequence"
    end

    validate_test_path!(test, stack)

    %{
      role: role,
      stack: stack,
      build_harness: build_harness,
      test: test,
      repetitions: repetitions,
      tolerances: tolerances,
      candidates: candidates
    }
  end

  def validate_matrix!(other) do
    raise "RoleModelSweep: matrix must decode to a JSON/YAML object, got: #{inspect(other)}"
  end

  defp require_string!(raw, key) do
    case Map.get(raw, key) do
      v when is_binary(v) and v != "" ->
        v

      other ->
        raise "RoleModelSweep: #{inspect(key)} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp require_repetitions!(raw) do
    case Map.get(raw, "repetitions") do
      n when is_integer(n) and n >= @min_repetitions ->
        n

      other ->
        raise "RoleModelSweep: \"repetitions\" must be an integer >= #{@min_repetitions}, got: #{inspect(other)}"
    end
  end

  defp require_tolerances!(raw) do
    case Map.get(raw, "tolerances") do
      %{"cost_pct" => cost_pct, "duration_pct" => duration_pct}
      when is_number(cost_pct) and cost_pct >= 0 and is_number(duration_pct) and duration_pct >= 0 ->
        %{cost_pct: cost_pct * 1.0, duration_pct: duration_pct * 1.0}

      other ->
        raise "RoleModelSweep: \"tolerances\" must be {cost_pct: <finite non-negative number>, " <>
                "duration_pct: <finite non-negative number>}, got: #{inspect(other)}"
    end
  end

  defp require_candidates!(raw) do
    case Map.get(raw, "candidates") do
      list when is_list(list) and list != [] ->
        candidates = Enum.map(list, &validate_candidate!/1)
        names = Enum.map(candidates, & &1.name)

        unless Enum.uniq(names) == names do
          raise "RoleModelSweep: candidate names must be unique, got: #{inspect(names)}"
        end

        candidates

      other ->
        raise "RoleModelSweep: \"candidates\" must be a non-empty list, got: #{inspect(other)}"
    end
  end

  @kebab_re ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  defp validate_candidate!(%{
         "name" => name,
         "harness" => harness,
         "model" => model,
         "effort" => effort
       })
       when is_binary(name) and is_binary(harness) and is_binary(model) and is_binary(effort) do
    unless Regex.match?(@kebab_re, name) do
      raise "RoleModelSweep: candidate name must be kebab-case, got: #{inspect(name)}"
    end

    unless harness in @valid_harnesses do
      raise "RoleModelSweep: candidate #{inspect(name)} harness must be one of #{inspect(@valid_harnesses)}, got: #{inspect(harness)}"
    end

    unless model != "" do
      raise "RoleModelSweep: candidate #{inspect(name)} model must be a non-empty string"
    end

    unless effort in @valid_efforts do
      raise "RoleModelSweep: candidate #{inspect(name)} effort must be one of #{inspect(@valid_efforts)}, got: #{inspect(effort)}"
    end

    %{name: name, harness: harness, model: model, effort: effort}
  end

  defp validate_candidate!(other) do
    raise "RoleModelSweep: each candidate must have name/harness/model/effort strings, got: #{inspect(other)}"
  end

  defp validate_test_path!(test, stack) do
    expected_dir = "test/stacks/#{stack}/"

    unless String.starts_with?(test, expected_dir) and String.ends_with?(test, "_test.exs") do
      raise "RoleModelSweep: \"test\" must be a relative path directly under #{expected_dir} " <>
              "ending in _test.exs, got: #{inspect(test)}"
    end

    abs = Path.expand(test, @codegen_root <> "/test_harness")
    expected_abs_prefix = Path.expand(expected_dir, @codegen_root <> "/test_harness")

    unless String.starts_with?(abs, expected_abs_prefix) do
      raise "RoleModelSweep: \"test\" escapes #{expected_dir} after path expansion: #{inspect(test)}"
    end

    unless File.exists?(abs) do
      raise "RoleModelSweep: test file not found: #{abs}"
    end

    content = File.read!(abs)

    unless content =~ "@moduletag :slow" do
      raise "RoleModelSweep: #{test} is not tagged @moduletag :slow — deterministic-only " <>
              "files are rejected before spend"
    end

    unless content =~ "Fixtures.run_codegen_build" or content =~ "Fixtures.change_request" do
      raise "RoleModelSweep: #{test} does not invoke a live build fixture " <>
              "(Fixtures.run_codegen_build or Fixtures.change_request) — rejected before spend"
    end
  end

  # ── Baseline resolution ─────────────────────────────────────────────────

  @doc """
  Resolves the campaign's baseline arm: the target role's CURRENT effective
  primary binding for `matrix.build_harness`, via the same
  `RoleResolver.resolve_harness/2` → `resolve_role/2` chain the live loop
  uses. This is generated, not authored — baseline and candidates share
  identical experiment mechanics.
  """
  @spec resolve_baseline(matrix()) :: candidate()
  def resolve_baseline(%{role: role, build_harness: build_harness}) do
    harness = RoleResolver.resolve_harness(role, build_harness)
    {model, effort} = RoleResolver.resolve_role(role, harness)
    %{name: "baseline", harness: harness, model: model, effort: effort}
  end

  # ── Cyclic arm/repetition schedule ──────────────────────────────────────

  @doc """
  Builds the deterministic cyclic execution schedule: round 1 starts with
  `arms` in order, each subsequent round rotates the first arm to the back
  by one. Spreads time/order load across arms instead of running every
  repetition of one arm before starting the next.

  Returns a flat list of `{arm, repetition_index}` tuples in execution
  order, `repetition_index` 1-based per arm.
  """
  @spec build_schedule([candidate()], pos_integer()) :: [{candidate(), pos_integer()}]
  def build_schedule(arms, repetitions) when is_list(arms) and arms != [] do
    n = length(arms)

    for round <- 0..(repetitions - 1), offset <- 0..(n - 1) do
      arm = Enum.at(rotate(arms, round), offset)
      {arm, round + 1}
    end
  end

  defp rotate(list, 0), do: list

  defp rotate(list, n) do
    {head, tail} = Enum.split(list, rem(n, length(list)))
    tail ++ head
  end

  # ── Median (odd: middle; even: mean of two middles) ─────────────────────

  @doc false
  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # ── Environment/tree preflight (shared by --validate-only and real run) ──

  @doc """
  Runs every no-spend preflight check: root worktree clean, selected test
  file exists (already checked in `validate_matrix!/1`), `yq` present,
  `mix`/gate tool resolvable, current HEAD + baseline resolve. Raises naming
  the failing contract on any red. Returns `%{sha: sha, baseline: candidate,
  platform: platform, cores: cores}` on success.
  """
  @spec preflight!(matrix()) :: %{
          sha: String.t(),
          baseline: candidate(),
          platform: String.t(),
          cores: pos_integer()
        }
  def preflight!(matrix) do
    unless System.find_executable("yq") do
      raise "RoleModelSweep: yq not found on PATH"
    end

    {porcelain, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: @codegen_root, stderr_to_stdout: true)

    unless String.trim(porcelain) == "" do
      raise "RoleModelSweep: codegen root worktree is dirty — commit or stash before running a campaign"
    end

    {sha_out, 0} =
      System.cmd("git", ["rev-parse", "HEAD"], cd: @codegen_root, stderr_to_stdout: true)

    sha = String.trim(sha_out)

    baseline = resolve_baseline(matrix)

    platform = normalize_platform(:os.type())
    cores = :erlang.system_info(:logical_processors_available)

    unless is_integer(cores) and cores > 0 do
      raise "RoleModelSweep: could not determine a positive logical core count"
    end

    %{sha: sha, baseline: baseline, platform: platform, cores: cores}
  end

  defp normalize_platform({:unix, :darwin}), do: "darwin"
  defp normalize_platform({:unix, :linux}), do: "linux"

  defp normalize_platform(other),
    do: raise("RoleModelSweep: unsupported platform: #{inspect(other)}")

  # ── Repetition execution ─────────────────────────────────────────────────

  @doc """
  Runs ONE arm × repetition: creates a standard benchmark run dir via
  `BenchManifest.start_run/2`, writes `role-model-binding.json` there,
  spawns the selected test file as a child `mix test <file> --only slow`
  with `HARNESS`, `BENCH_RUN_DIR`, and a campaign-unique `MIX_BUILD_PATH`,
  and records the child's exit code + whole-repetition wall duration.

  `run_fn` is a test seam — defaults to a real `System.cmd/3` spawn.
  """
  @spec run_repetition(matrix(), candidate(), String.t(), String.t(), keyword()) :: map()
  def run_repetition(matrix, arm, campaign_id, run_dir, opts \\ []) do
    run_fn = Keyword.get(opts, :run_fn, &default_run_fn/2)
    sha = Keyword.fetch!(opts, :sha)

    BenchManifest.start_run(run_dir, "role-model-sweep: #{campaign_id} arm=#{arm.name}")

    binding = %{
      "schema_version" => 1,
      "campaign_id" => campaign_id,
      "arm" => arm.name,
      "role" => matrix.role,
      "stack" => matrix.stack,
      "harness" => arm.harness,
      "model" => arm.model,
      "effort" => arm.effort,
      "source_sha" => sha,
      "fixed" => true
    }

    File.write!(
      Path.join(run_dir, "role-model-binding.json"),
      Jason.encode!(binding, pretty: true)
    )

    build_path_suffix = :erlang.unique_integer([:positive])
    mix_build_path = "_build/role_model_sweep_#{build_path_suffix}"

    env = [
      {"HARNESS", arm.harness},
      {"BENCH_RUN_DIR", run_dir},
      {"MIX_BUILD_PATH", mix_build_path}
    ]

    started = System.monotonic_time(:millisecond)
    {output, exit_code} = run_fn.(matrix.test, env)
    finished = System.monotonic_time(:millisecond)

    %{
      arm: arm.name,
      run_dir: run_dir,
      exit_code: exit_code,
      wall_ms: finished - started,
      output: output
    }
  end

  defp default_run_fn(test_file, env) do
    System.cmd("mix", ["test", test_file, "--only", "slow"],
      cd: Path.join(@codegen_root, "test_harness"),
      env: env,
      stderr_to_stdout: true
    )
  end

  # ── Classification ────────────────────────────────────────────────────────

  @doc """
  Classifies one repetition's completeness+provenance. A repetition is
  COMPLETE only when: child exited 0, at least one `harness_summary` exists
  in the run dir, every summary is `assertion_passed: true` with a known
  numeric cost, and the target role's dispatched tuple (from the loop's raw
  terminal `dispatches`) matches the arm's requested tuple exactly.

  Returns `{:complete, %{cost: float, summaries: n}} | {:incomplete, reason}`.
  """
  @spec classify_repetition(map(), matrix(), candidate()) ::
          {:complete, %{cost: float(), summaries: non_neg_integer()}} | {:incomplete, String.t()}
  def classify_repetition(%{exit_code: exit_code}, _matrix, _arm) when exit_code != 0 do
    {:incomplete, "child exited #{exit_code}"}
  end

  def classify_repetition(%{run_dir: run_dir, output: output}, matrix, arm) do
    loaded = BenchView.load_run(run_dir)

    case loaded.tests do
      [] ->
        {:incomplete, "no harness_summary records found"}

      tests ->
        with :ok <- all_summaries_passed_with_cost(tests) do
          dispatches = UsageParser.parse_dispatches(output)
          role_dispatches = Map.get(dispatches, matrix.role, [])

          if role_dispatches != [] and Enum.all?(role_dispatches, &dispatch_matches_arm?(&1, arm)) do
            cost = Enum.reduce(tests, 0.0, fn t, acc -> acc + numeric_cost(t.parsed.cost_usd) end)
            {:complete, %{cost: cost, summaries: length(tests)}}
          else
            {:incomplete, "missing or mismatched dispatch provenance for role #{matrix.role}"}
          end
        end
    end
  end

  defp all_summaries_passed_with_cost(tests) do
    if Enum.all?(tests, fn t -> t.assertion_passed == true and is_number(t.parsed.cost_usd) end) do
      :ok
    else
      {:incomplete, "a harness_summary was unpassed or carried an unknown cost"}
    end
  end

  defp numeric_cost(n) when is_number(n), do: n
  defp numeric_cost(_), do: 0.0

  defp dispatch_matches_arm?(%{harness: h, model: m, effort: e}, arm) do
    normalize_harness(h) == normalize_harness(arm.harness) and m == arm.model and e == arm.effort
  end

  defp normalize_harness("claude"), do: "claude_code"
  defp normalize_harness(other), do: other

  # ── Aggregation + verdict ─────────────────────────────────────────────────

  @doc """
  Aggregates all repetitions for one arm into `%{pass_rate, median_cost,
  min_cost, max_cost, median_wall_ms, min_wall_ms, max_wall_ms,
  complete_count, total_count}`.
  """
  @spec aggregate_arm([{map(), map()} | {map(), {:incomplete, String.t()}}]) :: map()
  def aggregate_arm(classified_repetitions) do
    total = length(classified_repetitions)

    completes =
      Enum.filter(classified_repetitions, fn {_rep, verdict} ->
        match?({:complete, _}, verdict)
      end)

    complete_count = length(completes)

    costs =
      Enum.map(completes, fn {_rep, {:complete, %{cost: cost}}} -> cost end)

    walls =
      Enum.map(completes, fn {rep, _verdict} -> rep.wall_ms end)

    %{
      pass_rate: if(total > 0, do: complete_count / total, else: 0.0),
      median_cost: median(costs),
      min_cost: if(costs == [], do: nil, else: Enum.min(costs)),
      max_cost: if(costs == [], do: nil, else: Enum.max(costs)),
      median_wall_ms: median(walls),
      min_wall_ms: if(walls == [], do: nil, else: Enum.min(walls)),
      max_wall_ms: if(walls == [], do: nil, else: Enum.max(walls)),
      complete_count: complete_count,
      total_count: total
    }
  end

  @doc """
  Computes the candidate verdict against the baseline aggregate + matrix
  tolerances. Baseline itself must already be all-complete (checked by the
  caller before candidates run) — this function assumes `baseline_agg.pass_rate
  == 1.0` and both medians are non-nil.
  """
  @spec candidate_verdict(map(), map(), matrix()) :: :viable | :rejected | :inconclusive
  def candidate_verdict(candidate_agg, baseline_agg, matrix) do
    cond do
      candidate_agg.complete_count != candidate_agg.total_count ->
        :inconclusive

      is_nil(candidate_agg.median_cost) or is_nil(candidate_agg.median_wall_ms) ->
        :inconclusive

      candidate_agg.pass_rate < baseline_agg.pass_rate ->
        :rejected

      candidate_agg.median_cost >
          baseline_agg.median_cost * (1 + matrix.tolerances.cost_pct / 100) ->
        :rejected

      candidate_agg.median_wall_ms >
          baseline_agg.median_wall_ms * (1 + matrix.tolerances.duration_pct / 100) ->
        :rejected

      true ->
        :viable
    end
  end
end
