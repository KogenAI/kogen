Code.require_file("../support/scenario_semantic.ex", __DIR__)

defmodule Kogen.ScenarioSemanticTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Contract

  @expected %{
    candidate_id: "tree-corrected",
    attempt_token: "attempt-7",
    scenario_ids: Kogen.ScenarioSemantic.scenario_ids()
  }

  test "rejects an accept-shaped response that has no scenario evidence" do
    response = %{
      "candidate_id" => "tree-corrected",
      "attempt_token" => "attempt-7",
      "verdict" => "accept",
      "scenarios" =>
        Enum.map(
          @expected.scenario_ids,
          &%{"id" => &1, "status" => "satisfied", "reason" => "looks complete", "evidence" => []}
        ),
      "dispositions" => [],
      "findings" => []
    }

    assert_raise ArgumentError, ~r/needs inspectable evidence/, fn ->
      Kogen.ScenarioSemantic.review_response!(response, @expected)
    end
  end

  test "requires a rework verdict to name the failing scenario and byte location" do
    response = review_response("rework", ["installed-artifact"], ["installed-artifact"])
    assert ^response = Kogen.ScenarioSemantic.review_response!(response, @expected)
  end

  test "accepts the corrected counterpart only when every scenario is evidenced" do
    response = review_response("accept", [], [])
    assert ^response = Kogen.ScenarioSemantic.review_response!(response, @expected)
  end

  test "complete-looking source and partial-routing claims fail all required focused proofs" do
    root = Path.join(System.tmp_dir!(), "kogen-semantic-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Kogen.ScenarioSemantic.write_fixture!(root, :incomplete)
    File.write!(Path.join(root, "Makefile"), "check:\n\t@true\n")
    contract = %{scenarios: Enum.map(@expected.scenario_ids, &%{"id" => &1}), risks: []}

    File.cd!(root, fn ->
      handoff = Kogen.ScenarioSemantic.handoff("current", :incomplete)

      assert {:ok, ^handoff} =
               Contract.handoff(Jason.encode!(handoff), contract, "current", [])

      assert {claimed, 0} = System.cmd("python3", ["probes/claimed_evidence.py"])
      assert claimed =~ "partial Developer"

      for id <- @expected.scenario_ids do
        {_output, status} = Kogen.ScenarioSemantic.focused_probe!(root, id)
        assert status != 0, "#{id} must expose concrete missing proof despite populated claims"
      end

      Kogen.ScenarioSemantic.write_fixture!(root, :corrected)
      corrected = Kogen.ScenarioSemantic.handoff("corrected", :corrected)

      assert {:ok, ^corrected} =
               Contract.handoff(Jason.encode!(corrected), contract, "corrected", [])

      for id <- @expected.scenario_ids do
        assert {_output, 0} = Kogen.ScenarioSemantic.focused_probe!(root, id)
      end
    end)
  end

  defp review_response(verdict, needs_rework, findings) do
    %{
      "candidate_id" => "tree-corrected",
      "attempt_token" => "attempt-7",
      "verdict" => verdict,
      "scenarios" =>
        Enum.map(@expected.scenario_ids, fn id ->
          %{
            "id" => id,
            "status" => if(id in needs_rework, do: "needs_rework", else: "satisfied"),
            "reason" => "inspected #{id}",
            "evidence" => [%{"path" => "fixture/#{id}.txt", "locator" => "line 1"}]
          }
        end),
      "dispositions" => [],
      "findings" =>
        Enum.map(findings, fn id ->
          %{
            "scenario_ids" => [id],
            "reason" => "#{id} is incomplete",
            "evidence" => [%{"path" => "fixture/#{id}.txt", "locator" => "line 1"}]
          }
        end)
    }
  end
end
