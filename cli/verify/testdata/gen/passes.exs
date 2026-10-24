# Writes cli/verify/testdata/golden/passes.json: verification passes (as the JSON that
# verify.Pass reads and writes) with the feedback Kogen.Build.pass_feedback/3 and the
# completeness verdict Kogen.Run.complete_pass?/4 (the Elixir reference) give for each.
#
#   cd <repo> && mise exec -- mix run --no-start cli/verify/testdata/gen/passes.exs

defmodule Gen do
  alias Kogen.{Build, Config, Gherkin, Intent, Run}

  @feature_text "Feature: F\n  Scenario: First\n    Given a\n    Then b\n  Scenario: Second\n    Then c\n"

  def scenarios(status_a \\ "passed", status_b \\ "passed", detail \\ nil) do
    {:ok, expected} = Gherkin.parse(@feature_text)
    [a, b] = expected
    [Map.merge(a, %{status: status_a, detail: detail}), Map.merge(b, %{status: status_b, detail: nil})]
  end

  def acceptance(scenarios \\ nil, opts \\ []) do
    scenarios = scenarios || scenarios()
    status = Keyword.get(opts, :status, 0)

    %{
      status: status,
      output: Keyword.get(opts, :output, "cucumber output\n"),
      scenarios: scenarios,
      problems: Keyword.get(opts, :problems, []),
      binding_problems: [],
      passed: Enum.count(scenarios, &(&1.status == "passed")),
      failed: Enum.count(scenarios, &(&1.status == "failed"))
    }
  end

  def cmd(name, command, status, output), do: %{name: name, command: command, status: status, output: output}

  def green_pass do
    %{
      n: 2,
      tree: String.duplicate("a", 40),
      clean: true,
      acceptance: acceptance(),
      model: {:ok, []},
      checks: [cmd("lint", "true", 0, "ok\n"), cmd("test", "mix test", 0, "fine\n")],
      setup: [cmd("setup-1", "npm ci", 0, "")],
      not_run: [],
      moved: [],
      failing: [],
      green: true
    }
  end

  def model_json(:none), do: "none"
  def model_json(:not_run), do: "not_run"
  def model_json({:ok, p}), do: %{"ok" => p}
  def model_json({:failed, p}), do: %{"failed" => p}

  def to_json(pass) do
    base = %{
      "n" => pass.n,
      "clean" => pass.clean,
      "green" => pass.green,
      "tree" => pass.tree,
      "acceptance" => if(pass.acceptance == :not_run, do: "not_run", else: stringify(pass.acceptance)),
      "model" => model_json(pass.model),
      "checks" => stringify(pass.checks),
      "moved" => pass.moved,
      "failing" => pass.failing
    }

    base = if Map.has_key?(pass, :setup), do: Map.put(base, "setup", stringify(pass.setup)), else: base
    if Map.has_key?(pass, :not_run), do: Map.put(base, "not_run", pass.not_run), else: base
  end

  def stringify(v), do: v |> JSON.encode!() |> JSON.decode!()

  def feedback_case(name, pass, run \\ "npm run accept", completion \\ nil) do
    b = %{config: %{acceptance_run: run}}

    fb =
      if completion,
        do: Build.pass_feedback(b, pass, completion),
        else: Build.pass_feedback(b, pass)

    %{
      "name" => name,
      "pass" => to_json(pass),
      "acceptance_run" => run,
      "completion" => completion,
      "feedback" => fb
    }
  end

  def complete_case(name, pass, config \\ nil, model \\ :none_or_ok) do
    root = Path.join(System.tmp_dir!(), "kogen-golden-complete-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".kogen/intents/f"))
    File.write!(Path.join(root, ".kogen/intents/f/acceptance.feature"), @feature_text)
    intent = %Intent{root: root, slug: "f"}
    config = config || %Config{setup: ["npm ci"], checks: [{"lint", "true"}, {"test", "mix test"}]}
    model = if model == :none_or_ok, do: :none, else: model
    ok = Run.complete_pass?(pass, config, intent, model)
    File.rm_rf!(root)

    %{
      "name" => name,
      "pass" => to_json(pass),
      "feature" => @feature_text,
      "setup" => config.setup,
      "checks" => Enum.map(config.checks, fn {n, c} -> %{"name" => n, "run" => c} end),
      "model" => if(model == :none, do: "none", else: "model"),
      "complete" => ok
    }
  end

  def run do
    long = Enum.map_join(1..90, "\n", &"out #{&1}") <> "\n"
    green = green_pass()
    problems = ["failed: First (line 2)\nacceptance.feature line 3: Given a\nboom", "unexpected: x.feature line 2 (y)"]
    failed_acc = acceptance(scenarios("failed", "passed", "boom"), status: 1, problems: problems)

    feedback = [
      feedback_case("acceptance failed", %{green | acceptance: failed_acc, green: false, failing: ["acceptance"], not_run: ["lint", "test"], checks: []}),
      feedback_case("acceptance failed other runner", %{green | acceptance: failed_acc, green: false, failing: ["acceptance"], not_run: ["lint"]}, "cucumber --strict"),
      feedback_case("setup failed", %{green | acceptance: :not_run, model: :none, checks: [], setup: [cmd("setup-1", "npm ci", 23, long)], not_run: ["setup-2", "acceptance", "lint", "test"], green: false, failing: ["setup-1"]}),
      feedback_case("model failed", %{green | model: {:failed, ["model.qnt: invariant Safe violated (seed 7)\nline a\nline b", "model.qnt: quint typecheck failed (status 1)\nx"]}, green: false, failing: ["model"], not_run: ["lint", "test"], checks: []}),
      feedback_case("check failed", %{green | checks: [cmd("lint", "true", 0, "ok"), cmd("test", "mix test", 2, long)], green: false, failing: ["test"]}),
      feedback_case("moved", %{green | moved: ["a.txt", "b/c.txt"], green: false}),
      feedback_case("moved with completion", %{green | moved: ["a.txt"], green: false}, "npm run accept", "submit_review"),
      feedback_case("everything", %{green | acceptance: failed_acc, model: {:failed, ["m"]}, checks: [cmd("lint", "true", 1, "bad\n")], setup: [cmd("setup-1", "x", 3, "s\n")], moved: ["z"], not_run: ["test"], failing: ["setup-1", "acceptance", "model", "lint"], green: false}),
      feedback_case("empty output", %{green | checks: [cmd("lint", "true", 1, "")], green: false, failing: ["lint"]}),
      feedback_case("model not run", %{green | model: :not_run, acceptance: :not_run, setup: [cmd("setup-1", "x", 1, "no\n")], checks: [], not_run: ["acceptance", "lint", "test"], green: false, failing: ["setup-1"]}),
      feedback_case("old pass without setup", Map.delete(Map.delete(%{green | checks: [cmd("lint", "true", 1, "bad\n")], green: false, failing: ["lint"]}, :setup), :not_run))
    ]

    complete = [
      complete_case("green", green),
      complete_case("green model", %{green | model: {:ok, []}}, nil, {:ok, []}),
      complete_case("model expected none got ok", %{green | model: {:ok, []}}),
      complete_case("model expected model got none", green, nil, {:ok, []}),
      complete_case("model failed", %{green | model: {:failed, ["x"]}}, nil, {:ok, []}),
      complete_case("not green", %{green | green: false}),
      complete_case("moved", %{green | moved: ["x"]}),
      complete_case("failing", %{green | failing: ["x"]}),
      complete_case("not_run", %{green | not_run: ["lint"]}),
      complete_case("not clean", %{green | clean: false}),
      complete_case("acceptance not run", %{green | acceptance: :not_run}),
      complete_case("acceptance exit 1", %{green | acceptance: acceptance(nil, status: 1)}),
      complete_case("acceptance problem", %{green | acceptance: acceptance(nil, problems: ["x"])}),
      complete_case("scenario failed", %{green | acceptance: acceptance(scenarios("failed", "passed"))}),
      complete_case("scenario count", %{green | acceptance: acceptance([hd(scenarios())])}),
      complete_case("scenario name", %{green | acceptance: acceptance(Enum.map(scenarios(), &%{&1 | name: &1.name <> "!"}))}),
      complete_case("scenario line", %{green | acceptance: acceptance(Enum.map(scenarios(), &%{&1 | line: &1.line + 1}))}),
      complete_case("passed count", %{green | acceptance: %{acceptance() | passed: 1}}),
      complete_case("check name", %{green | checks: [cmd("lint2", "true", 0, ""), cmd("test", "mix test", 0, "")]}),
      complete_case("check command", %{green | checks: [cmd("lint", "false", 0, ""), cmd("test", "mix test", 0, "")]}),
      complete_case("check status", %{green | checks: [cmd("lint", "true", 1, ""), cmd("test", "mix test", 0, "")]}),
      complete_case("check missing", %{green | checks: [cmd("lint", "true", 0, "")]}),
      complete_case("check order", %{green | checks: [cmd("test", "mix test", 0, ""), cmd("lint", "true", 0, "")]}),
      complete_case("setup command", %{green | setup: [cmd("setup-1", "npm i", 0, "")]}),
      complete_case("setup name", %{green | setup: [cmd("setup-2", "npm ci", 0, "")]}),
      complete_case("setup status", %{green | setup: [cmd("setup-1", "npm ci", 1, "")]}),
      complete_case("setup missing", %{green | setup: []}),
      complete_case("legacy without setup and not_run", Map.delete(Map.delete(green, :setup), :not_run)),
      complete_case("legacy with a different setup config", Map.delete(Map.delete(green, :setup), :not_run), %Config{setup: [], checks: [{"lint", "true"}, {"test", "mix test"}]})
    ]

    File.write!(
      Path.join(File.cwd!(), "cli/verify/testdata/golden/passes.json"),
      JSON.encode!(%{"feedback" => feedback, "complete" => complete}) <> "\n"
    )

    IO.puts("wrote #{length(feedback)} feedback, #{length(complete)} complete cases")
  end
end

Gen.run()
