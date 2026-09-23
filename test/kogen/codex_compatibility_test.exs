Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.Codex.CompatibilityTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Codex.Compatibility
  alias Kogen.RouteConfig

  test "evidence requires an initial rework, exact developer resume, and fresh accepting review" do
    evidence = %{
      "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
      "developer" => %{"session_id" => "developer-1"},
      "resume" => %{"session_id" => "developer-1"},
      "initial_reviewer" => %{
        "session_id" => "reviewer-1",
        "verdict" => "rework",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "needs_rework"}],
        "findings" => [%{"scenario_ids" => ["compatibility-runner"]}]
      },
      "final_reviewer" => %{
        "session_id" => "reviewer-2",
        "verdict" => "accept",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "satisfied"}]
      },
      "hostile_discovery" => %{
        "personal_marker" => false,
        "project_marker" => true,
        "root_receipt" => true,
        "shell_modes" => true,
        "helper_receipt" => true,
        "helper_environment" => true,
        "helper_context" => true,
        "resume_rework" => true,
        "hook_receipt" => true
      },
      "checks" => [
        %{"session_id" => "developer-1", "status" => "failed"},
        %{"session_id" => "developer-1", "status" => "passed"},
        %{"session_id" => "developer-1", "status" => "passed"}
      ],
      "checks_before_resume" => 2,
      "discovery_controls" => %{"ok" => true},
      "blocked_gate" => true
    }

    assert :ok = Compatibility.verify_evidence(evidence)

    stale = Map.put(evidence, "checks_before_resume", 3)
    assert {:error, _} = Compatibility.verify_evidence(stale)

    unrelated =
      Map.update!(stale, "checks", &(&1 ++ [%{"session_id" => "other", "status" => "passed"}]))

    assert {:error, _} = Compatibility.verify_evidence(unrelated)

    failed =
      put_in(
        evidence,
        ["checks"],
        Enum.take(evidence["checks"], 2) ++
          [%{"session_id" => "developer-1", "status" => "failed"}]
      )

    assert {:error, _} = Compatibility.verify_evidence(failed)
  end

  test "evidence rejects a fresh developer or a missing initial rework" do
    evidence = %{
      "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
      "developer" => %{"session_id" => "developer-1"},
      "resume" => %{"session_id" => "developer-2"},
      "initial_reviewer" => %{
        "session_id" => "reviewer-1",
        "verdict" => "rework",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "needs_rework"}],
        "findings" => [%{"scenario_ids" => ["compatibility-runner"]}]
      },
      "final_reviewer" => %{
        "session_id" => "reviewer-2",
        "verdict" => "accept",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "satisfied"}]
      },
      "hostile_discovery" => %{
        "personal_marker" => false,
        "project_marker" => true,
        "root_receipt" => true,
        "shell_modes" => true,
        "helper_receipt" => true,
        "helper_environment" => true,
        "helper_context" => true,
        "resume_rework" => true,
        "hook_receipt" => true
      },
      "checks" => [%{"session_id" => "developer-1", "status" => "failed"}],
      "checks_before_resume" => 2,
      "discovery_controls" => %{"ok" => true},
      "blocked_gate" => true
    }

    assert {:error, :incomplete_compatibility_evidence} = Compatibility.verify_evidence(evidence)
  end

  test "evidence rejects an accepting initial review or a reused final reviewer" do
    evidence = %{
      "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
      "developer" => %{"session_id" => "developer-1"},
      "resume" => %{"session_id" => "developer-1"},
      "initial_reviewer" => %{
        "session_id" => "reviewer-1",
        "verdict" => "accept",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "satisfied"}],
        "findings" => []
      },
      "final_reviewer" => %{
        "session_id" => "reviewer-1",
        "verdict" => "accept",
        "scenarios" => [%{"id" => "compatibility-runner", "status" => "satisfied"}]
      },
      "hostile_discovery" => %{
        "personal_marker" => false,
        "project_marker" => true,
        "root_receipt" => true,
        "shell_modes" => true,
        "helper_receipt" => true,
        "helper_environment" => true,
        "helper_context" => true,
        "resume_rework" => true,
        "hook_receipt" => true
      },
      "checks" => [
        %{"session_id" => "developer-1", "status" => "failed"},
        %{"session_id" => "developer-1", "status" => "passed"},
        %{"session_id" => "developer-1", "status" => "passed"}
      ],
      "checks_before_resume" => 2,
      "discovery_controls" => %{"ok" => true},
      "blocked_gate" => true
    }

    assert {:error, :incomplete_compatibility_evidence} = Compatibility.verify_evidence(evidence)
  end

  test "failed evidence names environment mismatches and preserves internal reviewer findings" do
    findings = [
      %{"description" => "helper HOME is private", "scenario_ids" => ["compatibility-runner"]}
    ]

    evidence = %{
      "hostile_discovery" => %{"root_receipt" => false, "helper_environment" => false},
      "final_reviewer" => %{"verdict" => "rework", "findings" => findings, "scenarios" => []}
    }

    assert {:error, {:compatibility_requirements_failed, failures}} =
             Compatibility.verify_evidence(evidence)

    assert {"root_receipt", :caller_environment_mismatch} in failures
    assert {"helper_environment", :caller_environment_mismatch} in failures
    assert {"final_reviewer", %{"findings" => findings, "scenarios" => []}} in failures
  end

  @tag :live
  @tag timeout: 900_000
  test "selected authenticated managed runtime passes the bounded compatibility runner" do
    config = RouteConfig.codex_route!()
    {:ok, runtime} = Kogen.Codex.installed()
    {:ok, scope} = Kogen.Codex.effective_scope(File.cwd!())
    assert :ok = Kogen.Codex.require_login(runtime, scope, File.cwd!())
    assert {:ok, evidence} = Compatibility.run(runtime, scope, config)
    assert File.regular?(evidence)
  end
end
