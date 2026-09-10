defmodule Kogen.ScenarioResponseTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../support/scenario_response.py", __DIR__)

  test "uses only the last tracking context for developer and reviewer fixture responses" do
    prompt = """
    stale text
    KOGEN_TRACKING_CONTEXT
    {"attempt_token":"stale-attempt","candidate_id":"stale-candidate","scenarios":[{"id":"stale","then":"stale claim"}]}
    current text
    KOGEN_TRACKING_CONTEXT
    {"attempt_token":"attempt-2","candidate_id":"candidate-2","scenarios":[{"id":"current","then":"current claim"}]}
    """

    developer = response!("developer", prompt)

    assert Map.keys(developer) |> Enum.sort() == [
             "attempt_token",
             "findings",
             "risks",
             "scenarios"
           ]

    assert developer["attempt_token"] == "attempt-2"
    assert [scenario] = developer["scenarios"]
    assert scenario["id"] == "current"
    assert scenario["status"] == "ready"
    assert scenario["claim"] == "current claim"
    assert [%{"path" => "Makefile", "locator" => "check"}] = scenario["implementation"]

    reviewer = response!("reviewer", prompt, "rework")
    assert reviewer["candidate_id"] == "candidate-2"
    assert reviewer["attempt_token"] == "attempt-2"
    assert reviewer["verdict"] == "rework"
    assert [%{"id" => "current", "status" => "needs_rework"}] = reviewer["scenarios"]
    assert [%{"scenario_ids" => ["current"]}] = reviewer["findings"]
  end

  defp response!(mode, prompt, verdict \\ nil) do
    args = [@helper, mode] ++ if verdict, do: [verdict], else: []

    driver =
      "import subprocess,sys; p=subprocess.run([sys.executable]+sys.argv[2:],input=sys.argv[1],text=True,capture_output=True); sys.stdout.write(p.stdout); sys.exit(p.returncode)"

    {output, 0} = System.cmd("python3", ["-c", driver, prompt | args])
    Jason.decode!(output)
  end
end
