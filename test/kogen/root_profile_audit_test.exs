Code.require_file("../support/root_profile_audit.ex", __DIR__)

defmodule Kogen.RootProfileAuditTest do
  use Kogen.IsolatedCase, async: true

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
      session!("shape-one", "gpt-6-astra", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-2.jsonl"),
      session!("shape-two", "gpt-6-astra", "low", fixture)
    )

    assert %{"sessions" => sessions_receipt} =
             Kogen.RootProfileAudit.audit_shape!(
               evidence,
               fixture,
               %{model: "gpt-6-astra", effort: "low"},
               sessions
             )

    assert Enum.map(sessions_receipt, & &1["role"]) == ["shaping", "shaping"]

    File.rm!(Path.join(sessions, "shape-2.jsonl"))

    assert_raise ArgumentError, ~r/exactly fresh and continued Shape/, fn ->
      Kogen.RootProfileAudit.audit_shape!(
        evidence,
        fixture,
        %{model: "gpt-6-astra", effort: "low"},
        sessions
      )
    end
  end

  test "ignores same-cwd child sessions and refuses a child used as a root" do
    {sessions, evidence} = fixture!()
    fixture = "/tmp/shape-fixture"

    File.write!(
      Path.join(sessions, "shape-1.jsonl"),
      session!("shape-one", "gpt-6-astra", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-2.jsonl"),
      session!("shape-two", "gpt-6-astra", "low", fixture)
    )

    File.write!(
      Path.join(sessions, "shape-child.jsonl"),
      session!("shape-child", "gpt-5.6-luna", "low", fixture, "shape-one")
    )

    assert %{"sessions" => [_one, _two]} =
             Kogen.RootProfileAudit.audit_shape!(
               evidence,
               fixture,
               %{model: "gpt-6-astra", effort: "low"},
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
end
