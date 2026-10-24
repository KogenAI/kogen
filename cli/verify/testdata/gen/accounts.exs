# Writes cli/verify/testdata/golden/accounts.json: Cucumber Messages reports and the result
# Kogen.Checks.account/5 (the Elixir reference) gives for each. The Go tests replay the same
# reports through verify.Account and compare by JSON value.
#
#   cd <repo> && mise exec -- mix run --no-start cli/verify/testdata/gen/accounts.exs

defmodule Gen do
  alias Kogen.{Checks, Gherkin}

  @feature "features/acceptance.feature"
  @root "/nonexistent/kogen-root"

  def feature_with_steps(name, step_count) do
    steps = Enum.map_join(1..step_count, "\n", &"    Given step #{&1}")
    text = "Feature: Accounting\n  Scenario: #{name}\n#{steps}\n"
    {:ok, expected} = Gherkin.parse(text)
    {text, expected}
  end

  def ast_ids(scenario, index, prefix \\ "case") do
    %{
      scenario: "ast-#{prefix}-scenario-#{index}",
      steps: Enum.map(1..length(scenario.steps), &"ast-#{prefix}-step-#{index}-#{&1}")
    }
  end

  def document_message(feature, scenarios, ast_id_sets) do
    children =
      Enum.zip(scenarios, ast_id_sets)
      |> Enum.map(fn {scenario, ids} ->
        steps =
          Enum.zip(scenario.steps, ids.steps)
          |> Enum.map(fn {step, id} ->
            %{"id" => id, "location" => %{"line" => step.line}, "keyword" => step.keyword}
          end)

        %{
          "scenario" => %{
            "id" => ids.scenario,
            "location" => %{"line" => scenario.line},
            "steps" => steps,
            "examples" => []
          }
        }
      end)

    %{"gherkinDocument" => %{"uri" => feature, "feature" => %{"children" => children}}}
  end

  def case_messages(scenario, feature, ast_scenario_ids, prefix, opts) do
    ast_step_ids =
      Keyword.get(
        opts,
        :ast_step_ids,
        Enum.with_index(scenario.steps, 1) |> Enum.map(fn {_s, i} -> "#{prefix}-ast-step-#{i}" end)
      )

    pickle_id = "#{prefix}-pickle"
    case_id = "#{prefix}-case"
    started_id = "#{prefix}-started"

    pickle_steps =
      Enum.zip(scenario.steps, ast_step_ids)
      |> Enum.with_index(1)
      |> Enum.map(fn {{step, ast_id}, index} ->
        %{"id" => "#{prefix}-pickle-step-#{index}", "astNodeIds" => [ast_id], "text" => step.text}
      end)

    test_steps =
      Enum.with_index(pickle_steps, 1)
      |> Enum.map(fn {pickle_step, index} ->
        %{"id" => "#{prefix}-test-step-#{index}", "pickleStepId" => pickle_step["id"]}
      end)

    test_steps =
      case Keyword.get(opts, :hook_first) do
        nil ->
          test_steps

        hook ->
          [%{"id" => "#{prefix}-hook-step", "hookId" => hook} | test_steps]
      end

    reported_count = Keyword.get(opts, :reported_step_count, length(test_steps))
    results = Keyword.get(opts, :results, List.duplicate(%{"status" => "PASSED"}, length(test_steps)))

    step_events =
      test_steps
      |> Enum.take(reported_count)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} ->
        %{
          "testStepFinished" => %{
            "testCaseStartedId" => started_id,
            "testStepId" => step["id"],
            "testStepResult" => Enum.at(results, index - 1)
          }
        }
      end)

    pickle = %{
      "pickle" => %{
        "id" => pickle_id,
        "uri" => feature,
        "name" => scenario.name,
        "astNodeIds" => ast_scenario_ids,
        "steps" => pickle_steps
      }
    }

    test_case = %{
      "testCase" => %{"id" => case_id, "pickleId" => pickle_id, "testSteps" => test_steps}
    }

    events = [pickle, test_case]
    started? = Keyword.get(opts, :started?, true)

    events =
      if started?,
        do: events ++ [%{"testCaseStarted" => %{"id" => started_id, "testCaseId" => case_id}}],
        else: events

    events = if started?, do: events ++ step_events, else: events

    if started? and Keyword.get(opts, :finish?, true) do
      events ++
        [
          %{
            "testCaseFinished" => %{
              "testCaseStartedId" => started_id,
              "willBeRetried" => Keyword.get(opts, :will_be_retried?, false)
            }
          }
        ]
    else
      events
    end
  end

  def simple(feature, expected, opts \\ []) do
    indexed = Enum.with_index(expected, 1)
    prefix = Keyword.get(opts, :prefix, "case")
    sets = Enum.map(indexed, fn {s, i} -> ast_ids(s, i, prefix) end)
    document = document_message(feature, expected, sets)
    repeat = Keyword.get(opts, :repeat, 1)

    cases =
      for {{scenario, index}, ids} <- Enum.zip(indexed, sets), copy <- 1..repeat do
        case_messages(
          scenario,
          feature,
          [ids.scenario],
          "#{prefix}-#{index}-#{copy}",
          opts |> Keyword.delete(:repeat) |> Keyword.delete(:prefix) |> Keyword.put(:ast_step_ids, ids.steps)
        )
      end

    [document | List.flatten(cases)]
  end

  def statuses(list), do: Enum.map(list, &%{"status" => &1})

  def entry(name, text, expected, lines, status, output) do
    report = "/tmp/kogen-golden-report.ndjson"

    File.rm(report)

    if lines != nil do
      File.write!(report, Enum.join(lines, "\n") <> if(lines == [], do: "", else: "\n"))
    end

    result = Checks.account(@root, @feature, expected, report, %{status: status, output: output})

    %{
      "name" => name,
      "feature" => text,
      "report" => lines,
      "status" => status,
      "output" => output,
      "result" => result
    }
  end

  def wrap_rule([%{"gherkinDocument" => d} | rest]) do
    children = d["feature"]["children"]
    rule = [%{"rule" => %{"children" => children}}]
    [%{"gherkinDocument" => put_in(d, ["feature", "children"], rule)} | rest]
  end

  def enc(events), do: Enum.map(events, &JSON.encode!/1)

  def run do
    {t1, e1} = feature_with_steps("one", 1)
    {t2, e2} = feature_with_steps("two", 2)
    {t3, e3} = feature_with_steps("three", 3)
    {tx, ex} = feature_with_steps("extra", 1)
    other = simple("features/unexpected.feature", ex, prefix: "unexpected")

    cases = []

    # The property of checks_test: every combination of finished, reported steps and status.
    cases =
      cases ++
        for status <- ~w(PASSED FAILED UNDEFINED PENDING SKIPPED AMBIGUOUS),
            {reported, finished, unexpected} <- [{2, true, false}, {2, true, true}, {1, true, false}, {2, false, false}, {0, true, false}] do
          ev = simple(@feature, e2, reported_step_count: reported, finish?: finished, statuses: nil, results: statuses([status, status]), prefix: "expected")
          ev = if unexpected, do: ev ++ other, else: ev
          entry("property #{status} reported=#{reported} finished=#{finished} unexpected=#{unexpected}", t2, e2, enc(ev), 0, "")
        end

    cases =
      cases ++
        [
          entry("mixed UNDEFINED", t2, e2, enc(simple(@feature, e2, results: statuses(["FAILED", "UNDEFINED"]))), 1, ""),
          entry("mixed AMBIGUOUS", t2, e2, enc(simple(@feature, e2, results: statuses(["FAILED", "AMBIGUOUS"]))), 1, ""),
          entry("mixed SKIPPED", t2, e2, enc(simple(@feature, e2, results: statuses(["FAILED", "SKIPPED"]))), 1, ""),
          entry("missing", t1, e1, enc(simple(@feature, e1, started?: false)), 0, ""),
          entry("duplicate", t1, e1, enc(simple(@feature, e1, repeat: 2)), 0, ""),
          entry("unexpected feature", t1, e1, enc(simple(@feature, e1, prefix: "expected") ++ simple("features/unexpected.feature", ex, prefix: "unexpected")), 0, ""),
          entry("nonzero exit", t1, e1, enc(simple(@feature, e1)), 7, "runner output"),
          entry("garbage line", t1, e1, enc(simple(@feature, e1)) ++ ["not-json"], 0, "some output\n"),
          entry("array line", t1, e1, enc(simple(@feature, e1)) ++ ["[1,2]"], 0, ""),
          entry("empty report", t1, e1, [], 0, "nothing\n"),
          entry("missing report", t1, e1, nil, 1, "Cucumber can only run on Node.js versions 22 || 24 || >=26\n"),
          entry("missing report long output", t1, e1, nil, 2, Enum.map_join(1..90, "\n", &"line #{&1}") <> "\n"),
          entry("three-step all passed", t3, e3, enc(simple(@feature, e3)), 0, "")
        ]

    # retry
    [scenario] = e2
    ids = ast_ids(scenario, 1)

    retry =
      [document_message(@feature, [scenario], [ids])] ++
        case_messages(scenario, @feature, [ids.scenario], "attempt-one", results: statuses(["FAILED", "FAILED"]), will_be_retried?: true, ast_step_ids: ids.steps) ++
        case_messages(scenario, @feature, [ids.scenario], "attempt-two", ast_step_ids: ids.steps)

    cases = cases ++ [entry("retry passes", t2, e2, enc(retry), 0, "")]

    retry_fail =
      [document_message(@feature, [scenario], [ids])] ++
        case_messages(scenario, @feature, [ids.scenario], "attempt-one", results: statuses(["FAILED", "FAILED"]), will_be_retried?: true, ast_step_ids: ids.steps) ++
        case_messages(scenario, @feature, [ids.scenario], "attempt-two", results: statuses(["PASSED", "FAILED"]), ast_step_ids: ids.steps)

    cases = cases ++ [entry("retry fails", t2, e2, enc(retry_fail), 1, "")]

    # failures with detail
    long = Enum.map_join(1..30, "\n", &"assertion line #{&1}")
    msg = %{"status" => "FAILED", "message" => long <> "\n"}
    exc = %{"status" => "FAILED", "exception" => %{"message" => "boom é\n  at x"}}
    big = %{"status" => "FAILED", "message" => String.duplicate("é", 11_000)}

    cases =
      cases ++
        [
          entry("failed long message", t2, e2, enc(simple(@feature, e2, results: [%{"status" => "PASSED"}, msg])), 1, "out\n"),
          entry("failed exception message", t2, e2, enc(simple(@feature, e2, results: [exc, %{"status" => "SKIPPED"}])), 1, ""),
          entry("failed huge message", t2, e2, enc(simple(@feature, e2, results: [%{"status" => "PASSED"}, big])), 1, ""),
          entry("failed no message", t2, e2, enc(simple(@feature, e2, results: statuses(["PASSED", "FAILED"]))), 1, ""),
          entry("pending", t2, e2, enc(simple(@feature, e2, results: statuses(["PENDING", "SKIPPED"]))), 1, ""),
          entry("unknown status", t2, e2, enc(simple(@feature, e2, results: statuses(["PASSED", "WEIRD"]))), 0, ""),
          entry("non-string message", t2, e2, enc(simple(@feature, e2, results: [%{"status" => "PASSED"}, %{"status" => "FAILED", "message" => 7}])), 1, "")
        ]

    # hooks
    hook_doc = [
      %{"hook" => %{"id" => "h1", "sourceReference" => %{"uri" => "features/steps/hooks.js", "location" => %{"line" => 5}}}},
      %{"hook" => %{"id" => "h2"}}
    ]

    hook_cases =
      for {name, hook} <- [{"hook with location", "h1"}, {"hook without location", "h2"}, {"hook unknown", "h9"}] do
        [doc | rest] = simple(@feature, e1, hook_first: hook, results: [%{"status" => "FAILED", "message" => "hook failed\n"}, %{"status" => "SKIPPED"}])
        entry(name, t1, e1, enc([doc | hook_doc ++ rest]), 1, "")
      end

    # outline
    outline_text = """
    Feature: Outline accounting
      Scenario Outline: value <value>
        Given the value is <value>
        Then it is accepted
      Examples:
        | value |
        | first |
        | second |
    """

    {:ok, oexp} = Gherkin.parse(outline_text)
    step_ids = ["outline-step-1", "outline-step-2"]

    rows = Enum.map(oexp, fn s -> %{"id" => "outline-row-#{s.line}", "location" => %{"line" => s.line}} end)
    first = hd(oexp)

    steps =
      Enum.zip(first.steps, step_ids)
      |> Enum.map(fn {step, id} -> %{"id" => id, "location" => %{"line" => step.line}, "keyword" => step.keyword} end)

    doc = %{
      "gherkinDocument" => %{
        "uri" => @feature,
        "feature" => %{
          "children" => [
            %{"scenario" => %{"id" => "outline-scenario", "location" => %{"line" => 2}, "steps" => steps, "examples" => [%{"tableBody" => rows}]}}
          ]
        }
      }
    }

    case_events =
      Enum.zip(oexp, rows)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{s, row}, i} ->
        case_messages(s, @feature, ["outline-scenario", row["id"]], "outline-#{i}", ast_step_ids: step_ids)
      end)

    outline_failed =
      Enum.zip(oexp, rows)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{s, row}, i} ->
        case_messages(s, @feature, ["outline-scenario", row["id"]], "outline-#{i}", ast_step_ids: step_ids, results: statuses(["PASSED", if(i == 2, do: "FAILED", else: "PASSED")]))
      end)

    cases =
      cases ++
        hook_cases ++
        [
          entry("outline", outline_text, oexp, enc([doc | case_events]), 0, ""),
          entry("outline one row fails", outline_text, oexp, enc([doc | outline_failed]), 1, "")
        ]

    # absolute uri under the root, and a pickle whose AST node is unknown
    abs_ev = simple("/nonexistent/kogen-root/features/acceptance.feature", e1)
    unknown_node = simple(@feature, e1)
    unknown_node = Enum.map(unknown_node, fn
      %{"pickle" => p} -> %{"pickle" => %{p | "astNodeIds" => ["no-such-node"]}}
      other -> other
    end)

    cases =
      cases ++
        [
          entry("absolute uri", t1, e1, enc(abs_ev), 0, ""),
          entry("unknown ast node", t1, e1, enc(unknown_node), 0, ""),
          entry("rule children", t1, e1, enc(wrap_rule(simple(@feature, e1))), 0, "")
        ]

    _ = tx

    File.write!(
      Path.join(File.cwd!(), "cli/verify/testdata/golden/accounts.json"),
      JSON.encode!(cases) <> "\n"
    )

    IO.puts("wrote #{length(cases)} cases")
  end
end

Gen.run()
