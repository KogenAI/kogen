defmodule Kogen.ScenarioTrackingTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Tracking

  test "persists a frozen, self-contained record and detects byte mutation" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries())
      assert state.path =~ ~r{\.kogen/runtime/scenario-tracking/[^/]+/record\.json$}
      assert :ok = Tracking.verify(state)

      record = Jason.decode!(state.bytes)
      assert record["schema_version"] == 1
      assert record["intent"]["id"] == "intent-1"
      assert record["scenarios"] == contract()["scenarios"]
      assert record["risks"] == contract()["risks"]
      assert record["risks_supplied"]
      assert record["attempts"] == []
      assert record["findings"] == []
      assert record["status"] == "pending"
      assert is_binary(record["approved_package_digest"])

      File.write!(state.path, state.bytes <> "tampered")
      assert {:error, reason} = Tracking.verify(state)
      assert reason =~ "changed outside Build"
    end)
  end

  test "creates exclusive records and durable updates" do
    in_private_cwd(fn ->
      assert {:ok, first} = Tracking.new(intent(), contract(), approved_entries())
      assert {:ok, second} = Tracking.new(intent(), contract(), approved_entries())
      refute first.path == second.path

      assert {:ok, state} = Tracking.start_attempt(first, "attempt-token-1", 1)
      changed = Map.put(state.record, "status", "failed")
      assert {:ok, updated} = Tracking.update(state, changed)
      assert :ok = Tracking.verify(updated)
      assert Jason.decode!(File.read!(updated.path))["status"] == "failed"

      altered = Map.put(changed, "scenarios", [])
      assert {:error, reason} = Tracking.update(updated, altered)
      assert reason =~ "frozen Approved inputs"
    end)
  end

  test "cited record versions allow controller updates but never external edits" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries())
      cited_bytes = state.bytes

      snapshot = %{
        "sha256" => Base.encode16(:crypto.hash(:sha256, cited_bytes)),
        "content_base64" => Base.encode64(cited_bytes),
        "binding" => "controller_record_version"
      }

      assert {:ok, updated} = Tracking.start_attempt(state, "next-attempt", 1)
      refute updated.bytes == cited_bytes
      assert :ok = Tracking.verify_reference(updated, "./" <> updated.path, snapshot)
      assert Base.decode64!(snapshot["content_base64"]) == cited_bytes

      other = Path.join(Path.dirname(updated.path), "ordinary-evidence.json")
      File.write!(other, cited_bytes)
      # Metadata cannot grant another file the controller's ownership policy.
      assert :ok = Tracking.verify_reference(updated, other, snapshot)
      File.write!(other, updated.bytes)
      assert {:error, reason} = Tracking.verify_reference(updated, other, snapshot)
      assert reason =~ "bound evidence reference mutated"

      # Restoring even a previously valid version is an unauthorized edit.
      File.write!(updated.path, cited_bytes)
      assert {:error, reason} = Tracking.verify_reference(updated, updated.path, snapshot)
      assert reason =~ "changed outside Build"
      assert {:error, _} = Tracking.update(updated, Map.put(updated.record, "status", "accepted"))
    end)
  end

  test "records an omitted optional risks file as not supplied" do
    in_private_cwd(fn ->
      legacy_contract = Map.delete(contract(), "risks")
      assert {:ok, state} = Tracking.new(intent(), legacy_contract, approved_entries())
      assert state.record["risks"] == []
      refute state.record["risks_supplied"]
    end)
  end

  test "preserves explicit false risk provenance with either key representation" do
    in_private_cwd(fn ->
      for legacy_contract <- [
            %{"scenarios" => [], "risks" => [], "risks_supplied" => false},
            %{scenarios: [], risks: [], risks_supplied: false}
          ] do
        assert {:ok, state} = Tracking.new(intent(), legacy_contract, approved_entries())
        refute state.record["risks_supplied"]
      end
    end)
  end

  test "atomically keeps finding origin and disposition history" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries())
      assert {:ok, state} = Tracking.start_attempt(state, "attempt-token-1", 1)
      assert {:ok, state} = bind_attempt(state, "candidate-1", "developer-1")

      rework = %{
        "verdict" => "rework",
        "dispositions" => [],
        "new_findings" => [
          %{
            "scenario_ids" => ["scenario-a"],
            "reason" => "missing proof",
            "evidence" => ["test/kogen/example_test.exs:12"]
          }
        ]
      }

      assert {:ok, state} =
               Tracking.apply_verdict(state, rework, "reviewer-1", %{
                 "test/kogen/example_test.exs" => "snapshot bytes"
               })

      assert [
               %{
                 "id" => "F1",
                 "scenario_ids" => ["scenario-a"],
                 "status" => "open",
                 "origin" => origin
               }
             ] =
               Tracking.open_findings(state)

      assert origin["reason"] == "missing proof"
      assert origin["scenario_ids"] == ["scenario-a"]
      assert origin["evidence"] == ["test/kogen/example_test.exs:12"]
      assert origin["candidate_id"] == "candidate-1"
      assert origin["attempt_token"] == "attempt-token-1"

      assert state.record["attempts"] |> List.last() |> Map.fetch!("reference_snapshots") == %{
               "test/kogen/example_test.exs" => "snapshot bytes"
             }

      assert origin["reviewer_session"] == "reviewer-1"

      assert {:ok, state} = Tracking.start_attempt(state, "attempt-token-2", 2)
      assert {:ok, state} = bind_attempt(state, "candidate-2", "developer-1")

      accept = %{
        "verdict" => "accept",
        "dispositions" => [
          %{
            "finding_id" => "F1",
            "status" => "closed",
            "reason" => "inspected fixed proof",
            "evidence" => ["test/kogen/example_test.exs:22"]
          }
        ],
        "new_findings" => []
      }

      assert {:ok, state} = Tracking.apply_verdict(state, accept, "reviewer-2")
      assert Tracking.open_findings(state) == []
      [finding] = state.record["findings"]
      assert finding["id"] == "F1"
      assert finding["origin"] == origin
      assert finding["status"] == "closed"

      assert [
               %{
                 "reviewer_session" => "reviewer-2",
                 "status" => "closed",
                 "reason" => "inspected fixed proof",
                 "evidence" => ["test/kogen/example_test.exs:22"]
               }
             ] =
               finding["disposition_history"]

      assert state.record["status"] == "accepted"
    end)
  end

  test "Reviewer citation preserves the Developer's earlier bytes for the same path" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries())
      assert {:ok, state} = Tracking.start_attempt(state, "attempt-1", 0)
      developer_bytes = state.bytes
      developer_refs = %{state.path => %{"content_base64" => Base.encode64(developer_bytes)}}

      attempts =
        List.update_at(state.record["attempts"], -1, fn attempt ->
          Map.merge(attempt, %{
            "developer_reference_snapshots" => developer_refs,
            "reference_snapshots" => developer_refs
          })
        end)

      assert {:ok, state} = Tracking.update(state, Map.put(state.record, "attempts", attempts))
      reviewer_bytes = state.bytes
      reviewer_refs = %{state.path => %{"content_base64" => Base.encode64(reviewer_bytes)}}
      verdict = %{"verdict" => "accept", "dispositions" => [], "findings" => []}

      assert {:ok, state} = Tracking.apply_verdict(state, verdict, "reviewer-1", reviewer_refs)
      attempt = List.last(Jason.decode!(File.read!(state.path))["attempts"])
      assert attempt["developer_reference_snapshots"] == developer_refs
      assert attempt["reviewer_reference_snapshots"] == reviewer_refs
      refute developer_bytes == reviewer_bytes
    end)
  end

  defp intent, do: %{"id" => "intent-1", "slug" => "sample", "title" => "Sample"}

  defp contract do
    %{
      "scenarios" => [%{"id" => "scenario-a", "then" => "works"}],
      "risks" => [%{"id" => "risk-a", "scenario_ids" => ["scenario-a"]}]
    }
  end

  defp approved_entries,
    do: [{"", :directory, 0o755}, {"intent.yaml", :regular, 0o644, "id: intent-1\n"}]

  defp bind_attempt(state, candidate_id, developer_session_id) do
    attempts =
      List.update_at(state.record["attempts"], -1, fn attempt ->
        attempt
        |> Map.put("candidate_id", candidate_id)
        |> Map.put("developer_session_id", developer_session_id)
      end)

    Tracking.update(state, Map.put(state.record, "attempts", attempts))
  end

  defp in_private_cwd(fun) do
    original = File.cwd!()

    directory =
      Path.join(System.tmp_dir!(), "kogen-tracking-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    try do
      File.cd!(directory, fun)
    after
      File.cd!(original)
      File.rm_rf!(directory)
    end
  end
end
