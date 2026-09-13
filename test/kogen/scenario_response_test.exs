defmodule Kogen.ScenarioResponseTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../support/scenario_response.py", __DIR__)

  test "uses only the last task context for developer and reviewer fixture responses" do
    prompt = """
    stale text
    KOGEN_TASK_CONTEXT
    {"attempt_token":"stale-attempt","candidate_id":"stale-candidate","scenarios":[{"id":"stale","then":"stale claim"}]}
    current text
    KOGEN_TASK_CONTEXT
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

  test "reads the authoritative record and rejects missing or stale locator bindings" do
    tmp = Path.join(System.tmp_dir!(), "kogen-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    record_path = Path.join(tmp, "record.json")

    File.write!(
      record_path,
      Jason.encode!(%{
        "attempts" => [%{"attempt_token" => "current", "candidate_id" => "tree"}],
        "scenarios" => [%{"id" => "from-record", "then" => "read current bytes"}],
        "risks" => [],
        "findings" => []
      })
    )

    valid = response!("developer", task_prompt(record_path, "current", "tree"))
    assert [%{"id" => "from-record"}] = valid["scenarios"]

    for {path, token, candidate} <- [
          {record_path, "stale", "tree"},
          {record_path, "current", "other"},
          {Path.join(tmp, "missing.json"), "current", "tree"}
        ] do
      {_output, status} = raw_response("developer", task_prompt(path, token, candidate))
      assert status != 0
    end
  end

  defp response!(mode, prompt, verdict \\ nil) do
    {output, 0} = raw_response(mode, prompt, verdict)
    Jason.decode!(output)
  end

  defp raw_response(mode, prompt, verdict \\ nil) do
    args = [@helper, mode] ++ if verdict, do: [verdict], else: []

    driver =
      "import subprocess,sys; p=subprocess.run([sys.executable]+sys.argv[2:],input=sys.argv[1],text=True,capture_output=True); sys.stdout.write(p.stdout); sys.exit(p.returncode)"

    System.cmd("python3", ["-c", driver, prompt | args], stderr_to_stdout: true)
  end

  defp task_prompt(path, token, candidate) do
    "KOGEN_TASK_CONTEXT\n" <>
      Jason.encode!(%{
        "tracking_path" => path,
        "attempt_token" => token,
        "candidate_id" => candidate
      })
  end
end
