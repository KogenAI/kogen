Code.require_file("../support/root_profile_audit.ex", __DIR__)
Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.RootProfileAuditTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.RouteConfig

  test "retains and validates every turn context for exact requested root ids" do
    {sessions, evidence} = fixture!()

    receipt =
      Kogen.RootProfileAudit.audit!(
        evidence,
        %{
          "developer-id" => %{role: "developer", model: "gpt-5.6-sol", effort: "low"},
          "reviewer-id" => %{role: "reviewer", model: "gpt-5.6-terra", effort: "medium"}
        },
        sessions
      )

    assert Enum.map(receipt["sessions"], & &1["id"]) == ["developer-id", "reviewer-id"]
    assert File.regular?(Path.join(evidence, "root-profile-developer-developer-id.jsonl"))
    assert File.regular?(Path.join(evidence, "root-profile-reviewer-reviewer-id.jsonl"))
  end

  test "rejects missing ids, missing contexts, and mismatched resumed profiles" do
    {sessions, evidence} = fixture!()
    expected = %{"developer-id" => %{role: "developer", model: "gpt-5.6-sol", effort: "low"}}

    assert_raise ArgumentError, ~r/missing native session metadata/, fn ->
      Kogen.RootProfileAudit.audit!(
        evidence,
        Map.put(expected, "missing", expected["developer-id"]),
        sessions
      )
    end

    File.write!(
      Path.join(sessions, "developer.jsonl"),
      Jason.encode!(%{
        "type" => "session_meta",
        "payload" => %{"id" => "developer-id", "cwd" => "/tmp/other"}
      }) <> "\n"
    )

    assert_raise ArgumentError, ~r/no turn_context metadata/, fn ->
      Kogen.RootProfileAudit.audit!(evidence, expected, sessions)
    end

    File.write!(
      Path.join(sessions, "developer.jsonl"),
      session!("developer-id", "gpt-5.6-sol", "low") <>
        Jason.encode!(%{"type" => "turn_context", "payload" => %{"model" => "gpt-5.6-sol"}}) <>
        "\n"
    )

    assert_raise ArgumentError, ~r/mismatched root model or effort/, fn ->
      Kogen.RootProfileAudit.audit!(evidence, expected, sessions)
    end
  end

  test "requires exactly fresh and continued Shape sessions for its fixture cwd" do
    {sessions, evidence} = fixture!()
    fixture = "/tmp/shape-fixture"

    File.write!(
      Path.join(sessions, "shape-1.jsonl"),
      session!("shape-one", "gpt-5.6-sol", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-2.jsonl"),
      session!("shape-two", "gpt-5.6-sol", "low", fixture)
    )

    assert %{"sessions" => sessions_receipt} =
             Kogen.RootProfileAudit.audit_shape!(
               evidence,
               fixture,
               %{model: "gpt-5.6-sol", effort: "low"},
               sessions
             )

    assert Enum.map(sessions_receipt, & &1["role"]) == ["shaping", "shaping"]

    File.rm!(Path.join(sessions, "shape-2.jsonl"))

    assert_raise ArgumentError, ~r/exactly fresh and continued Shape/, fn ->
      Kogen.RootProfileAudit.audit_shape!(
        evidence,
        fixture,
        %{model: "gpt-5.6-sol", effort: "low"},
        sessions
      )
    end
  end

  test "ignores same-cwd child sessions and refuses a child used as a root" do
    {sessions, evidence} = fixture!()
    fixture = "/tmp/shape-fixture"

    File.write!(
      Path.join(sessions, "shape-1.jsonl"),
      session!("shape-one", "gpt-5.6-sol", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-2.jsonl"),
      session!("shape-two", "gpt-5.6-sol", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-child.jsonl"),
      session!("shape-child", "gpt-5.6-luna", "low", fixture, "shape-one")
    )

    assert %{"sessions" => [_one, _two]} =
             Kogen.RootProfileAudit.audit_shape!(
               evidence,
               fixture,
               %{model: "gpt-5.6-sol", effort: "low"},
               sessions
             )

    assert_raise ArgumentError, ~r/is a child, not a root session/, fn ->
      Kogen.RootProfileAudit.audit!(
        evidence,
        %{"shape-child" => %{role: "shaping", model: "gpt-5.6-luna", effort: "low"}},
        sessions
      )
    end
  end

  test "unrelated historical duplicate IDs do not invalidate owned root evidence" do
    {sessions, evidence} = fixture!()
    old = session!("unrelated-history", "old-model", "low")
    File.write!(Path.join(sessions, "old-a.jsonl"), old)
    File.write!(Path.join(sessions, "old-b.jsonl"), old)
    expected = %{"developer-id" => %{role: "developer", model: "gpt-5.6-sol", effort: "low"}}
    assert %{"sessions" => [_]} = Kogen.RootProfileAudit.audit!(evidence, expected, sessions)

    File.cp!(Path.join(sessions, "developer.jsonl"), Path.join(sessions, "duplicate-owned.jsonl"))

    assert_raise ArgumentError, ~r/duplicate native session id: developer-id/, fn ->
      Kogen.RootProfileAudit.audit!(evidence, expected, sessions)
    end
  end

  defp fixture! do
    root =
      Path.join(System.tmp_dir!(), "kogen-root-profile-#{System.unique_integer([:positive])}")

    sessions = Path.join(root, "sessions")
    evidence = Path.join(root, "evidence")
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(sessions, "developer.jsonl"),
      session!("developer-id", "gpt-5.6-sol", "low")
    )

    File.write!(
      Path.join(sessions, "reviewer.jsonl"),
      session!("reviewer-id", "gpt-5.6-terra", "medium")
    )

    {sessions, evidence}
  end

  defp session!(id, model, effort, cwd \\ "/tmp/other", parent_thread_id \\ nil) do
    Jason.encode!(%{
      "type" => "session_meta",
      "payload" => %{"id" => id, "cwd" => cwd, "parent_thread_id" => parent_thread_id}
    }) <>
      "\n" <>
      Jason.encode!(%{
        "type" => "turn_context",
        "payload" => %{"model" => model, "effort" => effort}
      }) <> "\n"
  end

  test "Claude Code audits follow the project's harness and scope, not the caller's cwd" do
    base = Path.join(System.tmp_dir!(), "claude-audit-#{System.unique_integer([:positive])}")
    project = Path.join(base, "project")
    fixture = Path.join(base, "fixture")
    root = Path.join(base, "Kogen/claude")
    projects = Path.join(root, "accounts/shared/projects")
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.mkdir_p!(Path.join(fixture, ".kogen"))
    File.mkdir_p!(Path.join(projects, "-fixture"))
    File.mkdir_p!(Path.join(projects, "-unrelated"))
    on_exit(fn -> File.rm_rf!(base) end)
    System.put_env("KOGEN_CLAUDE_ROOT", root)

    RouteConfig.write!(
      Path.join(project, ".kogen/config.yaml"),
      [{"claude", RouteConfig.claude_route()}]
    )

    RouteConfig.write!(
      Path.join(fixture, ".kogen/config.yaml"),
      [{"codex", RouteConfig.codex_route()}]
    )

    File.write!(
      Path.join(projects, "-fixture/reviewer-id.jsonl"),
      transcript!(fixture, "claude-opus-5-5", "medium") <>
        Jason.encode!(%{
          "type" => "assistant",
          "isSidechain" => true,
          "cwd" => fixture,
          "message" => %{"model" => "claude-sonnet-5"}
        }) <> "\n"
    )

    File.write!(
      Path.join(projects, "-fixture/wrong-id.jsonl"),
      transcript!(fixture, "claude-sonnet-5", "medium")
    )

    File.write!(
      Path.join(projects, "-unrelated/other.jsonl"),
      transcript!("/elsewhere", "claude-opus-5-5", "medium")
    )

    # Called from inside a directory configured for Codex, the audit still uses
    # the project's Claude Code harness and scope.
    {sessions_root, evidence} =
      File.cd!(fixture, fn ->
        {Kogen.RootProfileAudit.sessions_root(project), Path.join(base, "evidence")}
      end)

    assert sessions_root == {:claude, Path.expand(projects)}
    profile = %{model: "claude-opus-5-5", effort: "medium", role: "reviewer"}

    assert %{"harness" => "claude", "sessions" => [receipt]} =
             Kogen.RootProfileAudit.audit!(evidence, %{"reviewer-id" => profile}, sessions_root)

    assert receipt["observed_root_models"] == ["claude-opus-5-5"]
    assert receipt["observed_efforts"] == ["medium"]

    assert_raise ArgumentError, ~r/root responses came from/, fn ->
      Kogen.RootProfileAudit.audit!(evidence, %{"wrong-id" => profile}, sessions_root)
    end

    assert_raise ArgumentError, ~r/recorded effort/, fn ->
      Kogen.RootProfileAudit.audit!(
        evidence,
        %{"reviewer-id" => %{profile | effort: "high"}},
        sessions_root
      )
    end

    assert_raise ArgumentError, ~r/missing Claude Code transcript/, fn ->
      Kogen.RootProfileAudit.audit!(evidence, %{"absent-id" => profile}, sessions_root)
    end

    # Both fixture sessions (and not the unrelated one) are selected by cwd;
    # the Sonnet root among them is rejected.
    assert_raise ArgumentError, ~r/wrong-id root responses came from/, fn ->
      Kogen.RootProfileAudit.audit_shape!(evidence, fixture, profile, sessions_root)
    end

    File.rm!(Path.join(projects, "-fixture/wrong-id.jsonl"))

    assert_raise ArgumentError, ~r/expected exactly fresh and continued/, fn ->
      Kogen.RootProfileAudit.audit_shape!(evidence, fixture, profile, sessions_root)
    end
  end

  test "sessions_root is role-aware: a hybrid route splits stores, a clean route does not" do
    base =
      Path.join(
        System.tmp_dir!(),
        "root-profile-route-aware-#{System.unique_integer([:positive])}"
      )

    project = Path.join(base, "project")
    File.mkdir_p!(Path.join(project, ".kogen"))
    on_exit(fn -> File.rm_rf!(base) end)

    hybrid_route = %{
      "shaping" => %{"harness" => "claude", "model" => "claude-opus-5-5", "effort" => "medium"},
      "developer" => %{
        "harness" => "claude",
        "model" => "claude-opus-5-5",
        "effort" => "medium"
      },
      "reviewer" => %{"harness" => "codex", "model" => "gpt-6-sol", "effort" => "high"},
      "expert" => %{"harness" => "codex", "model" => "gpt-6-sol", "effort" => "high"},
      "helpers" => %{
        "claude" => %{
          "scout" => %{"model" => "claude-sonnet-5", "effort" => "low"},
          "worker" => %{"model" => "claude-sonnet-5", "effort" => "medium"}
        },
        "codex" => %{
          "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
          "worker" => %{"model" => "gpt-6-luna", "effort" => "high"}
        }
      }
    }

    RouteConfig.write!(
      Path.join(project, ".kogen/config.yaml"),
      [
        {"claude", RouteConfig.claude_route()},
        {"claude-dominant-adversarial-codex", hybrid_route}
      ],
      default_route: "claude"
    )

    # On the unchanged claude default, every role selects the same (Claude
    # Code) store, exactly as on main -- with no route argument at all.
    assert {:claude, _} = Kogen.RootProfileAudit.sessions_root(project)
    assert {:claude, _} = Kogen.RootProfileAudit.sessions_root(project, :developer)
    assert {:claude, _} = Kogen.RootProfileAudit.sessions_root(project, :reviewer)

    # On the named hybrid route, Shaping and Developer stay on the Claude
    # Code store; Reviewer and Expert move to the Codex store. Both stores
    # are distinct paths, audited separately.
    assert {:claude, claude_root} =
             Kogen.RootProfileAudit.sessions_root(
               project,
               :developer,
               "claude-dominant-adversarial-codex"
             )

    codex_root =
      Kogen.RootProfileAudit.sessions_root(
        project,
        :reviewer,
        "claude-dominant-adversarial-codex"
      )

    refute match?({:claude, _}, codex_root)
    refute claude_root == codex_root

    assert Kogen.RootProfileAudit.sessions_root(
             project,
             :expert,
             "claude-dominant-adversarial-codex"
           ) == codex_root
  end

  defp transcript!(cwd, model, effort) do
    Jason.encode!(%{"type" => "user", "cwd" => cwd, "message" => %{"content" => "hi"}}) <>
      "\n" <>
      Jason.encode!(%{
        "type" => "assistant",
        "isSidechain" => false,
        "cwd" => cwd,
        "effort" => effort,
        "message" => %{"model" => model, "content" => [%{"type" => "text", "text" => "ok"}]}
      }) <> "\n"
  end
end
