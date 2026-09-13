defmodule Kogen.ScenarioContractTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Contract

  @scenario %{
    "id" => "one",
    "given" => "a valid input",
    "when" => "Build reads it",
    "then" => "it is retained",
    "wrong_result" => "it is lost",
    "verified_by" => ["check"],
    "evidence" => "a focused test"
  }

  @contract %{
    scenarios: [@scenario],
    risks: [
      %{"id" => "risk-one", "scenario_ids" => ["one"], "description" => "A useful risk"}
    ],
    risks_supplied: true,
    targets: ["check"],
    text: "- id: one\n"
  }

  @ref %{"path" => "README.md", "locator" => "Kogen"}
  @scenario_yaml """
  - id: one
    given: a valid input
    when: Build reads it
    then: it is retained
    wrong_result: it is lost
    verified_by: [check]
    evidence: a focused test
  """

  test "loads strict scenarios and optional risks without changing their YAML text" do
    dir = temp_dir!()
    File.write!(Path.join(dir, "scenarios.yaml"), @scenario_yaml)

    File.write!(
      Path.join(dir, "risks.yaml"),
      "- id: risk-one\n  scenario_ids: [one]\n  description: A useful risk\n"
    )

    assert {:ok, loaded} = Contract.load(dir)
    assert loaded.scenarios == [@scenario]
    assert loaded.risks == @contract.risks
    assert loaded.risks_supplied
    assert loaded.targets == ["check"]
    assert loaded.text == File.read!(Path.join(dir, "scenarios.yaml"))
  end

  test "rejects duplicate scenario IDs and dangling risk links" do
    dir = temp_dir!()
    File.write!(Path.join(dir, "scenarios.yaml"), @scenario_yaml <> @scenario_yaml)
    assert {:error, reason} = Contract.load(dir)
    assert reason =~ "scenarios.yaml"

    File.write!(Path.join(dir, "scenarios.yaml"), @scenario_yaml)

    File.write!(
      Path.join(dir, "risks.yaml"),
      "- id: risk\n  scenario_ids: [missing]\n  description: bad link\n"
    )

    assert {:error, reason} = Contract.load(dir)
    assert reason =~ "risks.yaml"
  end

  test "records an explicitly supplied empty risk analysis" do
    dir = temp_dir!()
    File.write!(Path.join(dir, "scenarios.yaml"), @scenario_yaml)
    File.write!(Path.join(dir, "risks.yaml"), "[]\n")

    assert {:ok, %{risks: [], risks_supplied: true}} = Contract.load(dir)
  end

  test "the Shaping ownership example uses scalar text for paths" do
    dir = temp_dir!()
    File.write!(Path.join(dir, "scenarios.yaml"), @scenario_yaml)

    ownership =
      Map.new(
        ~w(paths when_exists owner_after_creation owner_during_operation permitted_mutation validation git_state upgrade_behavior),
        &{&1, "fixture lifecycle description"}
      )

    ownership =
      Map.merge(ownership, %{
        "paths" => "dummy.txt",
        "owner_after_creation" => "fixture seed",
        "owner_during_operation" => "human user"
      })

    risk = %{
      "id" => "ownership",
      "scenario_ids" => ["one"],
      "description" => "Seed becomes user-owned",
      "ownership" => [ownership]
    }

    path = Path.join(dir, "risks.yaml")
    File.write!(path, Jason.encode!([risk]))
    assert {:ok, %{risks: [^risk]}} = Contract.load(dir)

    invalid = put_in(risk, ["ownership", Access.at(0), "paths"], ["dummy.txt"])
    File.write!(path, Jason.encode!([invalid]))
    assert {:error, reason} = Contract.load(dir)
    assert reason =~ "risks.yaml"
    assert File.read!(path) == Jason.encode!([invalid])
    prompt = File.read!("priv/kogen/prompts/shaping.md")
    assert prompt =~ "Every ownership field is a nonblank YAML string"
    assert prompt =~ "paths: dummy.txt"
  end

  test "missing-file findings cite an existing requirement instead of the absent path" do
    missing = "missing-reviewer-notes-#{System.unique_integer([:positive])}.md"

    evidence = %{
      "path" => "test/kogen/scenario_contract_test.exs",
      "locator" => "missing-file finding test; current tree inspection found #{missing} absent"
    }

    verdict = %{
      candidate_id: "candidate-1",
      attempt_token: "attempt-1",
      verdict: "rework",
      scenarios: [
        %{
          id: "one",
          status: "needs_rework",
          reason: "Required #{missing} is absent",
          evidence: [evidence]
        }
      ],
      dispositions: [],
      findings: [
        %{scenario_ids: ["one"], reason: "Create required #{missing}", evidence: [evidence]}
      ]
    }

    binding = %{candidate_id: "candidate-1", attempt_token: "attempt-1"}
    assert {:ok, _} = Contract.verdict(verdict, @contract, binding, [])

    invalid =
      put_in(verdict, [:scenarios, Access.at(0), :evidence], [%{evidence | "path" => missing}])

    assert {:error, _} = Contract.verdict(invalid, @contract, binding, [])

    assert File.read!("priv/kogen/prompts/reviewer.md") =~
             "Never put the absent filename in an evidence `path`"
  end

  test "requires a ready, exact handoff with local references" do
    handoff = %{
      "attempt_token" => "attempt-1",
      "scenarios" => [
        %{
          "id" => "one",
          "status" => "ready",
          "claim" => "Implemented it",
          "implementation" => [@ref],
          "evidence" => [@ref]
        }
      ],
      "risks" => [
        %{
          "id" => "risk-one",
          "scenario_ids" => ["one"],
          "response" => "Checked the risk",
          "evidence" => [@ref]
        }
      ],
      "findings" => [
        %{"id" => "old", "status" => "addressed", "response" => "Fixed", "evidence" => [@ref]}
      ]
    }

    assert {:ok, ^handoff} =
             Contract.handoff(Jason.encode!(handoff), @contract, "attempt-1", [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])

    incomplete = put_in(handoff, ["scenarios", Access.at(0), "status"], "incomplete")

    assert {:error, _} =
             Contract.handoff(Jason.encode!(incomplete), @contract, "attempt-1", [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])

    missing_file =
      put_in(handoff, ["scenarios", Access.at(0), "evidence"], [
        %{"path" => "missing", "locator" => "x"}
      ])

    assert {:error, _} =
             Contract.handoff(Jason.encode!(missing_file), @contract, "attempt-1", [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])
  end

  test "normalizes atom-key verdicts and enforces whole-response consistency" do
    accepted = %{
      candidate_id: "candidate-1",
      attempt_token: "attempt-1",
      verdict: "accept",
      scenarios: [%{id: "one", status: "satisfied", reason: "Inspected", evidence: [@ref]}],
      dispositions: [%{id: "old", status: "closed", reason: "Fixed", evidence: [@ref]}],
      findings: []
    }

    assert {:ok, normalized} =
             Contract.verdict(
               accepted,
               @contract,
               %{candidate_id: "candidate-1", attempt_token: "attempt-1"},
               [
                 %{"id" => "old", "scenario_ids" => ["one"]}
               ]
             )

    assert normalized["candidate_id"] == "candidate-1"
    assert is_map(hd(normalized["scenarios"]))

    invalid_accept = put_in(accepted, [:scenarios, Access.at(0), :status], "needs_rework")

    assert {:error, _} =
             Contract.verdict(
               invalid_accept,
               @contract,
               %{candidate_id: "candidate-1", attempt_token: "attempt-1"},
               [%{"id" => "old", "scenario_ids" => ["one"]}]
             )

    unexplained_rework =
      accepted
      |> Map.put(:verdict, "rework")
      |> Map.put(:dispositions, [
        %{id: "old", status: "closed", reason: "Fixed", evidence: [@ref]}
      ])
      |> put_in([:scenarios, Access.at(0), :status], "needs_rework")

    assert {:error, _} =
             Contract.verdict(
               unexplained_rework,
               @contract,
               %{candidate_id: "candidate-1", attempt_token: "attempt-1"},
               [%{"id" => "old", "scenario_ids" => ["one"]}]
             )
  end

  test "rejects a satisfied scenario that remains covered by a blocking finding" do
    second = Map.put(@scenario, "id", "two")
    contract = %{@contract | scenarios: [@scenario, second]}

    verdict = %{
      candidate_id: "candidate-1",
      attempt_token: "attempt-1",
      verdict: "rework",
      scenarios: [
        %{id: "one", status: "needs_rework", reason: "New defect", evidence: [@ref]},
        %{id: "two", status: "satisfied", reason: "Looks good", evidence: [@ref]}
      ],
      dispositions: [%{id: "old", status: "open", reason: "Still broken", evidence: [@ref]}],
      findings: [%{scenario_ids: ["one"], reason: "New defect", evidence: [@ref]}]
    }

    assert {:error, reason} =
             Contract.verdict(
               verdict,
               contract,
               %{candidate_id: "candidate-1", attempt_token: "attempt-1"},
               [%{"id" => "old", "scenario_ids" => ["two"]}]
             )

    assert reason =~ "unresolved finding"
  end

  test "rejects incomplete coverage, stale bindings, and unsafe handoff references" do
    open = [%{"id" => "old", "scenario_ids" => ["one"]}]
    handoff = valid_handoff()

    invalid_messages = [
      put_in(handoff, ["scenarios"], []),
      put_in(handoff, ["scenarios"], [hd(handoff["scenarios"]), hd(handoff["scenarios"])]),
      put_in(handoff, ["scenarios", Access.at(0), "id"], "unknown"),
      put_in(handoff, ["risks"], []),
      put_in(handoff, ["risks"], [hd(handoff["risks"]), hd(handoff["risks"])]),
      put_in(handoff, ["risks", Access.at(0), "id"], "unknown"),
      put_in(handoff, ["findings"], []),
      put_in(handoff, ["findings"], [hd(handoff["findings"]), hd(handoff["findings"])]),
      put_in(handoff, ["findings", Access.at(0), "id"], "unknown"),
      put_in(handoff, ["scenarios", Access.at(0), "evidence"], [
        %{"path" => "/etc/hosts", "locator" => "x"}
      ]),
      put_in(handoff, ["scenarios", Access.at(0), "evidence"], [
        %{"path" => <<0>>, "locator" => "x"}
      ]),
      put_in(handoff, ["scenarios", Access.at(0), "evidence"], [
        %{"path" => "README.md", "locator" => ""}
      ]),
      put_in(handoff, ["scenarios", Access.at(0), "evidence"], [
        %{"path" => "not-here", "locator" => "x"}
      ])
    ]

    Enum.each(invalid_messages, fn message ->
      assert {:error, _} = Contract.handoff(Jason.encode!(message), @contract, "attempt-1", open)
    end)

    blocked = put_in(handoff, ["findings", Access.at(0), "status"], "blocked")

    assert {:error, "handoff finding remains blocked: old"} =
             Contract.handoff(Jason.encode!(blocked), @contract, "attempt-1", open)

    assert {:error, reason} = Contract.handoff(Jason.encode!(handoff), @contract, "stale", open)
    assert reason =~ "attempt_token"
  end

  test "rejects a symlink reference and malformed verdict coverage or bindings" do
    link = "contract-ref-#{System.unique_integer([:positive])}"
    File.ln_s!("README.md", link)
    on_exit(fn -> File.rm(link) end)

    symlinked =
      put_in(valid_handoff(), ["scenarios", Access.at(0), "evidence"], [
        %{"path" => link, "locator" => "x"}
      ])

    assert {:error, _} = Contract.handoff(Jason.encode!(symlinked), @contract, "attempt-1", [])

    verdict = valid_verdict()
    binding = %{candidate_id: "candidate-1", attempt_token: "attempt-1"}
    old = [%{"id" => "old", "scenario_ids" => ["one"]}]

    for malformed <- [
          put_in(verdict, [:dispositions], []),
          put_in(verdict, [:dispositions], [hd(verdict.dispositions), hd(verdict.dispositions)]),
          put_in(verdict, [:scenarios], [])
        ] do
      assert {:error, _} = Contract.verdict(malformed, @contract, binding, old)
    end

    assert {:error, reason} =
             Contract.verdict(verdict, @contract, %{binding | candidate_id: "stale"}, old)

    assert reason =~ "candidate_id"

    assert {:error, reason} =
             Contract.verdict(verdict, @contract, %{binding | attempt_token: "stale"}, old)

    assert reason =~ "attempt_token"

    unknown_disposition = put_in(verdict, [:dispositions, Access.at(0), :id], "unknown")
    assert {:error, _} = Contract.verdict(unknown_disposition, @contract, binding, old)
  end

  test "coverage diagnostics distinguish missing, duplicate, unexpected, blank, and malformed entries" do
    contract = %{@contract | scenarios: [@scenario, Map.put(@scenario, "id", "two")]}
    base = valid_handoff()
    second = base["scenarios"] |> hd() |> Map.put("id", "two")
    base = %{base | "scenarios" => base["scenarios"] ++ [second]}

    cases = [
      {[hd(base["scenarios"])], ["missing expected ID \"two\""]},
      {base["scenarios"] ++ [second], ["duplicate ID \"two\" at positions 2, 3"]},
      {[hd(base["scenarios"]), %{second | "id" => "other"}],
       ["missing expected ID \"two\"", "unexpected ID \"other\" at position 2"]},
      {[hd(base["scenarios"]), %{second | "id" => " "}],
       ["position 2: field id must be nonblank text", "missing expected ID \"two\""]},
      {[hd(base["scenarios"]), "bad"],
       ["entry at position 2: expected an object", "missing expected ID \"two\""]}
    ]

    for {entries, details} <- cases do
      assert {:error, reason} =
               Contract.handoff(
                 Jason.encode!(%{base | "scenarios" => entries}),
                 contract,
                 "attempt-1",
                 [%{"id" => "old", "scenario_ids" => ["one"]}]
               )

      Enum.each(details, &assert(reason =~ &1))
      refute reason =~ "coverage is missing, duplicate, or invalid"
    end
  end

  test "aggregates independent handoff field and reference causes without malformed-reference cascades" do
    handoff = valid_handoff()
    scenario = hd(handoff["scenarios"])
    risk = hd(handoff["risks"])
    finding = hd(handoff["findings"])

    scenario = %{
      scenario
      | "status" => "incomplete",
        "claim" => "",
        "implementation" => [],
        "evidence" => [%{"path" => "lib", "locator" => "directory"}, "bad"]
    }

    risk = %{risk | "scenario_ids" => [], "response" => "", "evidence" => "bad"}

    finding = %{
      finding
      | "status" => "invalid",
        "response" => "",
        "evidence" => [%{"path" => "not-here", "locator" => "missing"}]
    }

    invalid = %{handoff | "scenarios" => [scenario], "risks" => [risk], "findings" => [finding]}

    assert {:error, reason} =
             Contract.handoff(Jason.encode!(invalid), @contract, "attempt-1", [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])

    expected = [
      "field status expected",
      "field claim must be nonblank",
      "field implementation expected a nonempty list",
      "evidence[1], path \"lib\": expected a regular file; found directory",
      "evidence[2] expected an object",
      "field response must be nonblank",
      "field evidence expected a nonempty list",
      "must exactly match the approved risk links",
      "expected addressed, blocked, or disputed",
      "path \"not-here\": file does not exist"
    ]

    Enum.each(expected, &assert(reason =~ &1))
  end

  test "verdict entry diagnostics aggregate while valid reordered coverage remains accepted" do
    second = Map.put(@scenario, "id", "two")
    contract = %{@contract | scenarios: [@scenario, second]}
    binding = %{candidate_id: "candidate-1", attempt_token: "attempt-1"}
    verdict = valid_verdict()
    first = hd(verdict.scenarios)
    reordered = %{verdict | scenarios: [%{first | id: "two"}, first]}

    assert {:ok, _} =
             Contract.verdict(reordered, contract, binding, [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])

    invalid =
      put_in(reordered, [:scenarios, Access.at(0)], %{
        first
        | id: "two",
          reason: "",
          evidence: [%{"path" => "lib", "locator" => "directory"}]
      })

    invalid = put_in(invalid, [:dispositions, Access.at(0), :status], "invalid")

    assert {:error, reason} =
             Contract.verdict(invalid, contract, binding, [
               %{"id" => "old", "scenario_ids" => ["one"]}
             ])

    assert reason =~
             "verdict scenarios: entry \"two\" at position 1: field reason must be nonblank text"

    assert reason =~ "evidence[1], path \"lib\": expected a regular file; found directory"

    assert reason =~
             "finding dispositions: entry \"old\" at position 1: field status expected closed or open"
  end

  defp valid_handoff do
    %{
      "attempt_token" => "attempt-1",
      "scenarios" => [
        %{
          "id" => "one",
          "status" => "ready",
          "claim" => "Implemented",
          "implementation" => [@ref],
          "evidence" => [@ref]
        }
      ],
      "risks" => [
        %{
          "id" => "risk-one",
          "scenario_ids" => ["one"],
          "response" => "Checked",
          "evidence" => [@ref]
        }
      ],
      "findings" => [
        %{"id" => "old", "status" => "addressed", "response" => "Fixed", "evidence" => [@ref]}
      ]
    }
  end

  defp valid_verdict do
    %{
      candidate_id: "candidate-1",
      attempt_token: "attempt-1",
      verdict: "accept",
      scenarios: [%{id: "one", status: "satisfied", reason: "Inspected", evidence: [@ref]}],
      dispositions: [%{id: "old", status: "closed", reason: "Fixed", evidence: [@ref]}],
      findings: []
    }
  end

  defp temp_dir! do
    dir = Path.join(System.tmp_dir!(), "kogen-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
