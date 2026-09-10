Code.require_file("../support/scenario_semantic.ex", __DIR__)

defmodule Kogen.LiveTest do
  @moduledoc """
  Real-provider `make live` only (never part of `make check`): direct
  `Kogen.Harness` probes against the real `codex` CLI (session identity,
  exact `Codex resume`, a schema-valid Reviewer Verdict), using the configured
  real models from the tracked `.kogen/config.yaml`. Cheap, fast,
  infrastructure-level evidence for the primitives the full real
  Shape-to-Commit lifecycle in `test/kogen/live_shape_to_build_test.exs`
  builds on.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Contract

  @moduletag :live
  @moduletag timeout: 600_000

  test "developer session identity, exact resume, and a schema-valid reviewer verdict" do
    {:ok, config} = Kogen.Intent.read_config()
    project_root = File.cwd!()
    log_dir = primitive_log_dir(project_root)
    fixture = primitive_fixture(project_root)

    setup_fixture(project_root, fixture)
    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")

    previous_raw_log_dir = System.get_env("KOGEN_RAW_LOG_DIR")
    System.put_env("KOGEN_RAW_LOG_DIR", log_dir)

    on_exit(fn ->
      restore_env("KOGEN_RAW_LOG_DIR", previous_raw_log_dir)
      File.rm_rf!(fixture)
    end)

    File.cd!(fixture, fn ->
      assert {:ok, %{session_id: session_id, result: result}} =
               Kogen.Harness.launch_developer(
                 "Reply with exactly the word PROBEOK and nothing else. Do not use any tools.",
                 config.developer.model,
                 config.developer.effort
               )

      # `codex exec --json` settles a turn with `turn.completed`; it does not
      # emit the legacy Claude-style `result` event. Keep this primitive probe
      # tied to the event that the Harness actually uses to establish settlement.
      assert result["type"] == "turn.completed"
      assert is_map(result["usage"])

      assert {:ok, %{session_id: ^session_id}} =
               Kogen.Harness.resume_developer(
                 session_id,
                 "Reply with exactly the word RESUMEOK and nothing else. Do not use any tools.",
                 config.developer.model,
                 config.developer.effort
               )

      assert {:ok,
              %{
                verdict: verdict,
                findings: findings,
                response: response,
                session_id: reviewer_session_id
              }} =
               Kogen.Harness.launch_reviewer(
                 "This is a schema probe, not a real review. Return only this valid structured " <>
                   "Reviewer response with no tools: {\"candidate_id\":\"primitive-candidate\",\"attempt_token\":\"primitive-attempt\",\"verdict\":\"accept\",\"scenarios\":[],\"dispositions\":[],\"findings\":[]}.",
                 config.reviewer.model,
                 config.reviewer.effort
               )

      assert verdict in ["accept", "rework"]
      assert is_list(findings)
      assert response["candidate_id"] == "primitive-candidate"
      assert response["attempt_token"] == "primitive-attempt"
      assert is_binary(reviewer_session_id)
      assert reviewer_session_id != session_id
    end)
  end

  test "independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart" do
    {:ok, config} = Kogen.Intent.read_config()
    project_root = File.cwd!()
    log_dir = primitive_log_dir(project_root)
    fixture = primitive_fixture(project_root)
    setup_fixture(project_root, fixture)

    on_exit(fn -> File.rm_rf!(fixture) end)

    File.cd!(fixture, fn ->
      Kogen.ScenarioSemantic.write_fixture!(fixture, :incomplete)
      stage_readiness_baseline!(fixture)
      incomplete_probes = probe_outcomes!(fixture)
      assert Enum.all?(incomplete_probes, &(&1.status != 0))
      write_probe_receipts!(fixture, :incomplete, incomplete_probes)
      incomplete_candidate = candidate_id!(fixture)

      incomplete =
        review_semantic_candidate!(config, incomplete_candidate, "semantic-attempt-incomplete")

      assert incomplete["verdict"] == "rework",
             "the Reviewer must independently reject the incomplete Candidate; response: #{inspect(incomplete)}"

      Kogen.ScenarioSemantic.review_response!(incomplete, %{
        candidate_id: incomplete_candidate,
        attempt_token: "semantic-attempt-incomplete",
        scenario_ids: semantic_scenario_ids()
      })

      Kogen.ScenarioSemantic.write_fixture!(fixture, :corrected)
      stage_readiness_baseline!(fixture)
      corrected_probes = probe_outcomes!(fixture)
      assert Enum.all?(corrected_probes, &(&1.status == 0))
      write_probe_receipts!(fixture, :corrected, corrected_probes)
      corrected_candidate = candidate_id!(fixture)

      corrected =
        review_semantic_candidate!(config, corrected_candidate, "semantic-attempt-corrected")

      assert corrected["verdict"] == "accept",
             "the Reviewer must independently accept the corrected Candidate; response: #{inspect(corrected)}"

      Kogen.ScenarioSemantic.review_response!(corrected, %{
        candidate_id: corrected_candidate,
        attempt_token: "semantic-attempt-corrected",
        scenario_ids: semantic_scenario_ids()
      })

      File.write!(
        Path.join(log_dir, "semantic-incomplete-review.json"),
        Jason.encode!(incomplete)
      )

      File.write!(Path.join(log_dir, "semantic-corrected-review.json"), Jason.encode!(corrected))
    end)
  end

  # This is a read-only Reviewer challenge, never a Build run. The deliberately
  # incomplete Candidate looks plausible at a glance: source code has the new
  # command, a happy-path route, and a documented flag. Its installed command,
  # invalid configuration route, and actual flag readiness are each wrong.
  defp review_semantic_candidate!(config, candidate_id, attempt_token) do
    handoff = Kogen.ScenarioSemantic.handoff(attempt_token, attempt_state(attempt_token))
    contract = %{scenarios: semantic_contract(), risks: []}

    assert {:ok, ^handoff} =
             Contract.handoff(Jason.encode!(handoff), contract, attempt_token, [])

    tracking_context = %{
      "attempt_token" => attempt_token,
      "candidate_id" => candidate_id,
      "scenarios" => semantic_contract(),
      "risks" => [],
      "open_findings" => [],
      "developer_handoff" => handoff,
      "observed_focused_probes" =>
        Enum.map(semantic_scenario_ids(), fn id ->
          path = ".semantic-evidence/#{attempt_state(attempt_token)}-#{id}.json"
          %{path: path, receipt: Jason.decode!(File.read!(path))}
        end)
    }

    prompt = """
    Independently assess this Candidate against the full contract and supplied handoff below. Inspect the files yourself, use the focused probes as evidence where useful, and make your own verdict. Do not modify anything and do not run a gate. Use the exact supplied Candidate and attempt token. Every scenario needs one independent assessment; every evidence reference must use an existing repository-relative file path and a useful locator. Retained earlier receipts are history; assess the current Candidate and current supplied observations.

    Scenarios:
    #{Jason.encode!(semantic_contract())}

    KOGEN_TRACKING_CONTEXT
    #{Jason.encode!(tracking_context)}
    """

    assert {:ok,
            %{session_id: session_id, response: response, verdict: verdict, findings: findings}} =
             Kogen.Harness.launch_reviewer(prompt, config.reviewer.model, config.reviewer.effort)

    assert session_id != ""
    assert verdict == response["verdict"]
    assert findings == response["findings"]

    assert {:ok, ^response} =
             Contract.verdict(
               response,
               contract,
               %{candidate_id: candidate_id, attempt_token: attempt_token},
               []
             )

    response
  end

  defp semantic_scenario_ids, do: Kogen.ScenarioSemantic.scenario_ids()

  defp candidate_id!(fixture) do
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)
    {candidate, 0} = System.cmd("git", ["write-tree"], cd: fixture)
    String.trim(candidate)
  end

  defp stage_readiness_baseline!(fixture) do
    flags = Path.join(fixture, "config/flags.json")
    File.write!(flags, "{\"feature\": false}\n")
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)
    File.write!(flags, "{\"feature\": true}\n")
  end

  defp probe_outcomes!(fixture) do
    Enum.map(semantic_scenario_ids(), fn id ->
      {output, status} = Kogen.ScenarioSemantic.focused_probe!(fixture, id)
      %{scenario_id: id, status: status, output: output}
    end)
  end

  defp write_probe_receipts!(fixture, state, outcomes) do
    dir = Path.join(fixture, ".semantic-evidence")
    File.mkdir_p!(dir)

    Enum.each(outcomes, fn outcome ->
      File.write!(
        Path.join(dir, "#{state}-#{outcome.scenario_id}.json"),
        Jason.encode!(outcome) <> "\n"
      )
    end)
  end

  defp attempt_state(token),
    do: if(String.ends_with?(token, "incomplete"), do: :incomplete, else: :corrected)

  defp semantic_contract do
    [
      %{
        "id" => "installed-artifact",
        "given" => "a copied source implementation and an installed artifact",
        "when" => "the installed artifact is invoked",
        "then" => "the artifact itself reports installed artifact ready",
        "wrong_result" => "a source copy is cited while the installed command remains legacy",
        "verified_by" => ["check"],
        "evidence" => "probes/installed_artifact.py"
      },
      %{
        "id" => "role-routing",
        "given" => "configured Developer, Reviewer, and Shaper profiles",
        "when" =>
          "each role is routed with its declared model and effort or invalid configuration",
        "then" =>
          "all three valid combinations route and every invalid configuration is rejected",
        "wrong_result" => "only one role routes or invalid configuration succeeds",
        "verified_by" => ["check"],
        "evidence" => "probes/role_routing.py"
      },
      %{
        "id" => "git-status-readiness",
        "given" => "a tracked readiness flag marked assume-unchanged",
        "when" => "readiness is evaluated",
        "then" => "content divergence is detected despite clean git status",
        "wrong_result" => "status-only readiness treats hidden flag changes as ready",
        "verified_by" => ["check"],
        "evidence" => "probes/git_status_readiness.py"
      }
    ]
  end

  defp primitive_log_dir(project_root) do
    dir =
      Path.join(
        project_root,
        ".kogen/runtime/live-evidence/primitives-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp primitive_fixture(project_root) do
    runtime_root = Path.join(project_root, ".kogen/runtime/live-primitives")
    File.mkdir_p!(runtime_root)

    Path.join(
      runtime_root,
      "fixture-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp setup_fixture(project_root, fixture) do
    hooks_dir = Path.join(fixture, ".codex/hooks")
    File.mkdir_p!(hooks_dir)

    File.cp!(
      Path.join(project_root, ".codex/hooks.json"),
      Path.join(fixture, ".codex/hooks.json")
    )

    File.cp!(Path.join(project_root, ".codex/hooks/check.sh"), Path.join(hooks_dir, "check.sh"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(hooks_dir, "verification_policy.py")
    )

    File.chmod!(Path.join(hooks_dir, "check.sh"), 0o755)
    File.write!(Path.join(fixture, "Makefile"), ".PHONY: check\ncheck:\n\t@true\n")
    File.write!(Path.join(fixture, "README.md"), "Live primitive fixture\n")

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
