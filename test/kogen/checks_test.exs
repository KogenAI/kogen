defmodule Kogen.ChecksTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kogen.{Checks, Gherkin}

  @feature "features/acceptance.feature"

  property "VER-4: only generated reports with a finished complete scenario and no extras pass" do
    check all(
            step_count <- StreamData.integer(1..5),
            reported_steps <- StreamData.integer(0..step_count),
            step_status <-
              StreamData.member_of([
                "PASSED",
                "FAILED",
                "UNDEFINED",
                "PENDING",
                "SKIPPED",
                "AMBIGUOUS"
              ]),
            finished <- StreamData.boolean(),
            unexpected <- StreamData.boolean()
          ) do
      root = temp_dir("property")
      {_feature_text, expected} = feature_with_steps("generated", step_count)

      try do
        events =
          simple_messages(@feature, expected,
            reported_step_count: reported_steps,
            finish?: finished,
            statuses: List.duplicate(step_status, step_count),
            prefix: "expected"
          )

        events =
          if unexpected do
            {_other_text, other_expected} = feature_with_steps("extra", 1)

            events ++
              simple_messages("features/unexpected.feature", other_expected, prefix: "unexpected")
          else
            events
          end

        report = write_report!(root, "generated.ndjson", events)
        actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

        complete = finished and reported_steps == step_count
        scenario_passed = complete and step_status == "PASSED"
        expected_status = if complete, do: String.downcase(step_status), else: "report_invalid"

        if scenario_passed and not unexpected do
          assert actual.problems == []
        else
          refute actual.problems == []
        end

        assert hd(actual.scenarios).status == expected_status
        assert actual.passed == if(scenario_passed, do: 1, else: 0)

        if unexpected do
          assert Enum.any?(actual.problems, &String.starts_with?(&1, "unexpected:"))
        end
      after
        File.rm_rf!(root)
      end
    end
  end

  test "SHP-8: binding problems survive failed assertions, unlike ordinary skipped steps" do
    root = temp_dir("mixed-binding")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("mixed", 2)

    for status <- ["UNDEFINED", "AMBIGUOUS", "SKIPPED"] do
      report =
        write_report!(
          root,
          "#{status}.ndjson",
          simple_messages(@feature, expected, statuses: ["FAILED", status])
        )

      actual = Checks.account(root, @feature, expected, report, %{status: 1, output: ""})
      assert hd(actual.scenarios).status == "failed"

      if status == "SKIPPED" do
        assert actual.binding_problems == []
      else
        assert [problem] = actual.binding_problems
        assert problem =~ "#{String.downcase(status)} step:"
      end
    end
  end

  test "VER-4: an expected scenario absent from the report is missing" do
    root = temp_dir("missing")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("expected", 1)
    events = simple_messages(@feature, expected, started?: false)
    report = write_report!(root, "missing-scenario.ndjson", events)

    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert hd(actual.scenarios).status == "missing"
    assert actual.problems == ["missing: expected (line 2)"]
  end

  test "VER-4: the same scenario key reported twice is duplicate" do
    root = temp_dir("duplicate")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("duplicated", 1)
    events = simple_messages(@feature, expected, repeat: 2)
    report = write_report!(root, "duplicate.ndjson", events)

    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert hd(actual.scenarios).status == "duplicate"
    assert actual.problems == ["duplicate: duplicated (line 2)"]
  end

  test "VER-4: a result for an unexpected feature remains a problem" do
    root = temp_dir("unexpected")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("expected", 1)
    {_other_text, other_expected} = feature_with_steps("unexpected", 1)

    events =
      simple_messages(@feature, expected, prefix: "expected") ++
        simple_messages("features/unexpected.feature", other_expected, prefix: "unexpected")

    report = write_report!(root, "unexpected.ndjson", events)
    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert hd(actual.scenarios).status == "passed"
    assert actual.problems == ["unexpected: features/unexpected.feature line 2 (unexpected)"]
  end

  test "VER-4: willBeRetried excludes the failed attempt when the retry passes" do
    root = temp_dir("retry")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("retried", 2)
    [scenario] = expected
    ast_ids = ast_ids(scenario, 1)

    events =
      [document_message(@feature, [scenario], [ast_ids])] ++
        scenario_case_messages(scenario, @feature, [ast_ids.scenario], "attempt-one",
          statuses: ["FAILED", "FAILED"],
          will_be_retried?: true,
          ast_step_ids: ast_ids.steps
        ) ++
        scenario_case_messages(scenario, @feature, [ast_ids.scenario], "attempt-two",
          ast_step_ids: ast_ids.steps
        )

    report = write_report!(root, "retry.ndjson", events)
    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert hd(actual.scenarios).status == "passed"
    assert actual.problems == []
    assert actual.passed == 1
  end

  test "VER-4: truncated reports without a finished case or a result for every step are invalid" do
    root = temp_dir("truncated")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("truncated", 2)

    cases = [
      {"unfinished", [finish?: false]},
      {"missing-step-result", [reported_step_count: 1]}
    ]

    for {name, options} <- cases do
      events = simple_messages(@feature, expected, options)
      report = write_report!(root, "#{name}.ndjson", events)
      actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

      assert hd(actual.scenarios).status == "report_invalid"
      assert hd(actual.problems) =~ "report_invalid: truncated (line 2)"
    end
  end

  test "VER-4: a garbage line makes the report invalid" do
    root = temp_dir("garbage")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("garbage", 1)
    report = write_report!(root, "garbage.ndjson", simple_messages(@feature, expected))
    File.write!(report, File.read!(report) <> "not-json\n")

    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert [problem] = actual.problems
    assert String.starts_with?(problem, "report_invalid: the acceptance command exited 0")
    assert hd(actual.scenarios).status == "report_invalid"
  end

  test "VER-4: a missing report is reported once with the command's exit status and output" do
    root = temp_dir("report-missing")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("missing report", 1)
    report = Path.join(root, "does-not-exist.ndjson")

    actual =
      Checks.account(root, @feature, expected, report, %{
        status: 1,
        output: "Cucumber can only run on Node.js versions 22 || 24 || >=26\n"
      })

    assert actual.problems == [
             "report_missing: the acceptance command exited 1; its output:\nCucumber can only run on Node.js versions 22 || 24 || >=26"
           ]

    assert hd(actual.scenarios).status == "report_missing"
  end

  test "VER-4: a nonzero exit with every scenario passed is still a problem" do
    root = temp_dir("exit-status")
    on_exit(fn -> File.rm_rf!(root) end)
    {_text, expected} = feature_with_steps("passed", 1)
    report = write_report!(root, "passed.ndjson", simple_messages(@feature, expected))

    actual =
      Checks.account(root, @feature, expected, report, %{status: 7, output: "runner output"})

    assert hd(actual.scenarios).status == "passed"
    assert actual.problems == ["exit 7 with all scenarios passed"]
    assert actual.status == 7
  end

  test "VER-3 / VER-4: Scenario Outline results use each Examples row line as the key" do
    root = temp_dir("outline")
    on_exit(fn -> File.rm_rf!(root) end)

    feature_text = """
    Feature: Outline accounting
      Scenario Outline: value <value>
        Given the value is <value>
        Then it is accepted
      Examples:
        | value |
        | first |
        | second |
    """

    assert {:ok, expected} = Gherkin.parse(feature_text)
    assert Enum.map(expected, &{&1.name, &1.line}) == [{"value first", 7}, {"value second", 8}]

    outline_id = "outline-scenario"
    step_ids = ["outline-step-1", "outline-step-2"]
    row_ids = Enum.map(expected, &"outline-row-#{&1.line}")
    doc = outline_document(@feature, outline_id, step_ids, expected, 2)

    case_events =
      Enum.zip(expected, row_ids)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{scenario, row_id}, index} ->
        scenario_case_messages(
          scenario,
          @feature,
          [outline_id, row_id],
          "outline-#{index}",
          ast_step_ids: step_ids
        )
      end)

    events = [doc | case_events]

    report = write_report!(root, "outline.ndjson", events)
    actual = Checks.account(root, @feature, expected, report, %{status: 0, output: ""})

    assert Enum.map(actual.scenarios, &{&1.name, &1.line, &1.status}) == [
             {"value first", 7, "passed"},
             {"value second", 8, "passed"}
           ]

    assert actual.problems == []
  end

  defp feature_with_steps(name, step_count) do
    steps = Enum.map_join(1..step_count, "\n", &"    Given step #{&1}")
    text = "Feature: Accounting\n  Scenario: #{name}\n#{steps}\n"
    {:ok, expected} = Gherkin.parse(text)
    {text, expected}
  end

  defp simple_messages(feature, expected, opts \\ []) do
    indexed = Enum.with_index(expected, 1)
    prefix = Keyword.get(opts, :prefix, "case")

    ast_id_sets =
      Enum.map(indexed, fn {scenario, index} -> ast_ids(scenario, index, prefix) end)

    document = document_message(feature, expected, ast_id_sets)
    repeat = Keyword.get(opts, :repeat, 1)

    cases =
      for {{scenario, index}, ids} <- Enum.zip(indexed, ast_id_sets),
          copy <- 1..repeat,
          do:
            scenario_case_messages(
              scenario,
              feature,
              [ids.scenario],
              "#{prefix}-#{index}-#{copy}",
              opts
              |> Keyword.delete(:repeat)
              |> Keyword.delete(:prefix)
              |> Keyword.put(:ast_step_ids, ids.steps)
            )

    [document | List.flatten(cases)]
  end

  defp ast_ids(scenario, index, prefix \\ "case") do
    %{
      scenario: "ast-#{prefix}-scenario-#{index}",
      steps: Enum.map(1..length(scenario.steps), &"ast-#{prefix}-step-#{index}-#{&1}")
    }
  end

  defp document_message(feature, scenarios, ast_id_sets) do
    children =
      Enum.zip(scenarios, ast_id_sets)
      |> Enum.map(fn {scenario, ids} ->
        steps =
          Enum.zip(scenario.steps, ids.steps)
          |> Enum.map(fn {step, id} ->
            %{
              "id" => id,
              "location" => %{"line" => step.line},
              "keyword" => step.keyword
            }
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

  defp scenario_case_messages(scenario, feature, ast_scenario_ids, prefix, opts) do
    ast_step_ids =
      Keyword.get(
        opts,
        :ast_step_ids,
        Enum.with_index(scenario.steps, 1)
        |> Enum.map(fn {_s, i} -> "#{prefix}-ast-step-#{i}" end)
      )

    pickle_id = "#{prefix}-pickle"
    case_id = "#{prefix}-case"
    started_id = "#{prefix}-started"

    pickle_steps =
      Enum.zip(scenario.steps, ast_step_ids)
      |> Enum.with_index(1)
      |> Enum.map(fn {{step, ast_id}, index} ->
        %{
          "id" => "#{prefix}-pickle-step-#{index}",
          "astNodeIds" => [ast_id],
          "text" => step.text
        }
      end)

    test_steps =
      Enum.with_index(pickle_steps, 1)
      |> Enum.map(fn {pickle_step, index} ->
        %{
          "id" => "#{prefix}-test-step-#{index}",
          "pickleStepId" => pickle_step["id"]
        }
      end)

    reported_count = Keyword.get(opts, :reported_step_count, length(test_steps))
    statuses = Keyword.get(opts, :statuses, List.duplicate("PASSED", length(test_steps)))

    step_events =
      test_steps
      |> Enum.take(reported_count)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} ->
        %{
          "testStepFinished" => %{
            "testCaseStartedId" => started_id,
            "testStepId" => step["id"],
            "testStepResult" => %{"status" => Enum.at(statuses, index - 1)}
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

    events =
      if Keyword.get(opts, :started?, true),
        do: events ++ [%{"testCaseStarted" => %{"id" => started_id, "testCaseId" => case_id}}],
        else: events

    events = if Keyword.get(opts, :started?, true), do: events ++ step_events, else: events

    if Keyword.get(opts, :started?, true) and Keyword.get(opts, :finish?, true) do
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

  defp outline_document(feature, outline_id, step_ids, expected, outline_line) do
    [first | _] = expected

    steps =
      Enum.zip(first.steps, step_ids)
      |> Enum.map(fn {step, id} ->
        %{
          "id" => id,
          "location" => %{"line" => step.line},
          "keyword" => step.keyword
        }
      end)

    rows =
      Enum.map(expected, fn scenario ->
        %{"id" => "outline-row-#{scenario.line}", "location" => %{"line" => scenario.line}}
      end)

    %{
      "gherkinDocument" => %{
        "uri" => feature,
        "feature" => %{
          "children" => [
            %{
              "scenario" => %{
                "id" => outline_id,
                "location" => %{"line" => outline_line},
                "steps" => steps,
                "examples" => [%{"tableBody" => rows}]
              }
            }
          ]
        }
      }
    }
  end

  defp write_report!(root, name, events) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    text = Enum.map_join(events, "\n", &JSON.encode!/1) <> "\n"
    File.write!(path, text)
    path
  end

  defp temp_dir(label) do
    root =
      Path.join(System.tmp_dir!(), "kogen-checks-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end

  # Regression: a long `quint typecheck` failure reached the shaper as its last
  # 30 lines, which held only the code excerpt; the error message itself is printed first.
  test "VER-5 model feedback keeps the error Quint prints first and the summary it prints last" do
    output =
      Enum.join(
        ["", " Error [QNT000]: Couldn't unify set and list"] ++
          Enum.map(1..70, &"    #{&1}: nondet position = 0.to(tasks.length() - 1).oneOf()") ++
          ["error: typechecking failed"],
        "\n"
      )

    excerpt = Kogen.Checks.excerpt(output)
    assert excerpt =~ "Error [QNT000]: Couldn't unify set and list"
    assert String.ends_with?(excerpt, "error: typechecking failed")
    assert length(String.split(excerpt, "\n")) == 51
  end

  test "VER-5 short model feedback is kept whole" do
    output = "Error [QNT205]: nondet bindings\n  at model.qnt:3:5\nerror: typechecking failed\n"
    assert Kogen.Checks.excerpt(output) == String.trim_trailing(output)
  end
end
