defmodule Kogen.ScenarioTrackingTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Tracking

  test "persists a frozen, self-contained record and detects byte mutation" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
      assert state.path =~ ~r{\.kogen/runtime/scenario-tracking/[^/]+/record\.json$}
      assert :ok = Tracking.verify(state)

      record = Jason.decode!(state.bytes)
      assert record["schema_version"] == 2
      assert record["intent"]["id"] == "intent-1"
      assert record["scenarios"] == contract()["scenarios"]
      assert record["risks"] == contract()["risks"]
      assert record["risks_supplied"]
      assert record["attempts"] == []
      assert record["findings"] == []
      assert record["status"] == "pending"
      assert is_binary(record["approved_package_digest"])

      assert record["route"] == %{
               "name" => "codex",
               "harness" => "codex",
               "shaping" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
               "developer" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
               "reviewer" => %{"model" => "gpt-5.6-terra", "effort" => "medium"},
               "helpers" => %{
                 "scout" => %{"model" => "gpt-5.6-luna", "effort" => "low"},
                 "worker" => %{"model" => "gpt-5.6-luna", "effort" => "medium"},
                 "expert" => %{"model" => "gpt-5.6-sol", "effort" => "medium"}
               }
             }

      File.write!(state.path, state.bytes <> "tampered")
      assert {:error, reason} = Tracking.verify(state)
      assert reason =~ "changed outside Build"
    end)
  end

  test "refuses to create a record from a route missing a required key" do
    in_private_cwd(fn ->
      broken = route() |> Map.delete(:reviewer)

      assert {:error, reason} = Tracking.new(intent(), contract(), approved_entries(), broken)
      assert reason =~ "scenario tracking route lacks reviewer"
    end)
  end

  test "version 2 holds notes, Jev evidence and the controller report while earlier records stay unrewritten" do
    in_private_cwd(fn ->
      legacy_dir = ".kogen/runtime/scenario-tracking/legacy-build"
      File.mkdir_p!(legacy_dir)
      legacy_path = Path.join(legacy_dir, "record.json")

      legacy_bytes =
        Jason.encode!(%{
          "schema_version" => 1,
          "attempts" => [
            %{
              "developer_message" => ~s({"attempt_token":"old"}),
              "developer_invocation" => %{"schema" => "{}", "schema_sha256" => "x"},
              "handoff" => %{"attempt_token" => "old", "scenarios" => []},
              "failure" => "Developer handoff structure invalid: old history"
            }
          ]
        })

      File.write!(legacy_path, legacy_bytes)

      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
      assert {:ok, state} = Tracking.start_attempt(state, "token-2", 0)

      attempt =
        state.record["attempts"]
        |> List.last()
        |> Map.merge(%{
          "developer_notes" => %{"label" => "unverified", "text" => "done", "sha256" => "d"},
          "jev" => %{"outcome" => "unavailable", "reason" => "timeout", "request" => %{}},
          "outcome" => "settled",
          "handoff" => %{
            "format" => "kogen-controller-handoff-report",
            "built_by" => "controller"
          }
        })

      assert {:ok, updated} =
               Tracking.update(state, Map.put(state.record, "attempts", [attempt]))

      record = Jason.decode!(File.read!(updated.path))
      assert record["schema_version"] == 2
      [stored] = record["attempts"]
      assert stored["handoff"]["built_by"] == "controller"
      assert stored["jev"]["outcome"] == "unavailable"
      assert stored["developer_notes"]["label"] == "unverified"

      # Earlier Builds' records are readable history, never migrated.
      assert File.read!(legacy_path) == legacy_bytes
      refute updated.path == legacy_path
    end)
  end

  test "prompts describe the controller-built report and free-prose notes, not a JSON handoff" do
    root = System.fetch_env!("KOGEN_TEST_ROOT")
    squish = &(&1 |> File.read!() |> String.replace(~r/\s+/, " "))
    developer = squish.(Path.join(root, "priv/kogen/prompts/developer.md"))
    reviewer = squish.(Path.join(root, "priv/kogen/prompts/reviewer.md"))

    assert developer =~ "## Final Developer notes"
    assert developer =~ "Do not write a JSON handoff"
    assert developer =~ "no Kogen code parses your final message"
    assert developer =~ "name anything still unfinished"

    assert developer =~
             "state that objection plainly in one short paragraph naming the scenario, risk or finding and the reason"

    assert developer =~ "Answer every open Reviewer finding in prose"
    assert developer =~ "return to Shaping"
    refute developer =~ "output only this JSON object"
    refute developer =~ "controller-owned schema"
    refute developer =~ ~s("status": "ready" | "incomplete")

    assert reviewer =~ "It contains no Developer self-assessment"

    assert reviewer =~
             "you are responsible for finding unfinished or plausible-looking-only scenarios"

    assert reviewer =~ "including prose responses to open findings, are unverified claims"
    assert reviewer =~ "TypeSafe Jev read only those words, never the code"
    assert reviewer =~ "are advisory labels, never findings or verification"
    assert reviewer =~ "only your verdict decides acceptance or rework"

    assert reviewer =~
             "`changed_affected_paths` lists files that changed relative to HEAD, not where each behaviour lives"
  end

  test "creates exclusive records and durable updates" do
    in_private_cwd(fn ->
      assert {:ok, first} = Tracking.new(intent(), contract(), approved_entries(), route())
      assert {:ok, second} = Tracking.new(intent(), contract(), approved_entries(), route())
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

  test "refuses any update that changes the frozen route, name or a single profile" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())

      renamed = Map.put(state.record, "route", Map.put(state.record["route"], "name", "other"))
      assert {:error, reason} = Tracking.update(state, renamed)
      assert reason =~ "frozen Approved inputs"

      changed_model =
        put_in(state.record, ["route", "developer", "model"], "gpt-different")

      assert {:error, reason} = Tracking.update(state, changed_model)
      assert reason =~ "frozen Approved inputs"

      changed_helper =
        put_in(state.record, ["route", "helpers", "scout", "effort"], "high")

      assert {:error, reason} = Tracking.update(state, changed_helper)
      assert reason =~ "frozen Approved inputs"

      # An update that leaves route untouched still succeeds.
      assert {:ok, updated} =
               Tracking.update(state, Map.put(state.record, "status", "failed"))

      assert updated.record["route"] == state.record["route"]
    end)
  end

  test "a legacy record with no route field still updates and verifies consistently" do
    in_private_cwd(fn ->
      legacy_record =
        %{
          "schema_version" => 1,
          "purpose" => "inspection evidence; not a recovery checkpoint",
          "intent" => intent(),
          "approved_package_digest" => "legacy-digest",
          "scenarios" => contract()["scenarios"],
          "risks" => contract()["risks"],
          "risks_supplied" => true,
          "attempts" => [],
          "findings" => [],
          "status" => "pending"
        }

      refute Map.has_key?(legacy_record, "route")

      path = "legacy-record.json"
      bytes = Jason.encode!(legacy_record) <> "\n"
      File.write!(path, bytes)
      legacy_state = %{path: path, bytes: bytes, record: legacy_record}

      assert :ok = Tracking.verify(legacy_state)

      assert {:ok, updated} =
               Tracking.update(legacy_state, Map.put(legacy_record, "status", "failed"))

      refute Map.has_key?(updated.record, "route")
      assert :ok = Tracking.verify(updated)

      # Introducing a route on a legacy record through a generic update is
      # itself a frozen-field change and must be refused.
      assert {:error, reason} =
               Tracking.update(updated, Map.put(updated.record, "route", route_json()))

      assert reason =~ "frozen Approved inputs"
    end)
  end

  test "cited record versions allow controller updates but never external edits" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
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
      assert {:ok, state} = Tracking.new(intent(), legacy_contract, approved_entries(), route())
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
        assert {:ok, state} = Tracking.new(intent(), legacy_contract, approved_entries(), route())
        refute state.record["risks_supplied"]
      end
    end)
  end

  test "atomically keeps finding origin and disposition history" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
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

  test "a record citation is a digest-bound sidecar, never an inline copy of the record" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
      assert {:ok, state} = Tracking.start_attempt(state, "attempt-1", 0)
      cited = state.bytes
      digest = Base.encode16(:crypto.hash(:sha256, cited), case: :lower)
      sidecar = Path.join(Path.dirname(state.path), "record-versions/#{digest}.json")

      assert {:ok, snapshot} = Tracking.retain_record_version(state, cited)

      assert snapshot == %{
               "path" => state.path,
               "sha256" => digest,
               "byte_count" => byte_size(cited),
               "binding" => "controller_record_version",
               "sidecar" => sidecar
             }

      assert File.read!(sidecar) == cited

      # Identical bytes reuse the exclusive file; a second citation adds nothing.
      assert {:ok, ^snapshot} = Tracking.retain_record_version(state, cited)
      assert File.ls!(Path.dirname(sidecar)) == ["#{digest}.json"]

      attempts =
        List.update_at(
          state.record["attempts"],
          -1,
          &Map.put(&1, "reference_snapshots", %{state.path => snapshot})
        )

      assert {:ok, state} = Tracking.update(state, Map.put(state.record, "attempts", attempts))
      refute state.bytes =~ Base.encode64(cited)
      assert :ok = Tracking.verify_reference(state, state.path, snapshot)
      assert :ok = Tracking.verify_record_versions(state)

      File.write!(sidecar, cited <> " edited")
      assert {:error, reason} = Tracking.verify_record_versions(state)
      assert reason =~ "record version sidecar mutated"
      assert {:error, _} = Tracking.verify_reference(state, state.path, snapshot)

      # Different bytes under an existing digest name are an integrity failure.
      assert {:error, reason} = Tracking.retain_record_version(state, cited)
      assert reason =~ "record version sidecar integrity failure"

      File.rm!(sidecar)
      assert {:error, reason} = Tracking.verify_record_versions(state)
      assert reason =~ "record version sidecar missing"

      # A snapshot cannot point its sidecar anywhere but its digest name.
      File.write!(sidecar, cited)
      moved = Path.join(Path.dirname(state.path), "elsewhere.json")
      File.write!(moved, cited)

      assert {:error, _} =
               Tracking.verify_reference(state, state.path, %{snapshot | "sidecar" => moved})

      # Older records inline the cited version and stay valid as written.
      legacy = %{
        "sha256" => Base.encode16(:crypto.hash(:sha256, cited)),
        "content_base64" => Base.encode64(cited),
        "binding" => "controller_record_version"
      }

      assert :ok = Tracking.verify_reference(state, state.path, legacy)
    end)
  end

  test "Reviewer citation preserves the Developer's earlier bytes for the same path" do
    in_private_cwd(fn ->
      assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route())
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

  defp route do
    %{
      route: "codex",
      harness: "codex",
      shaping: %{model: "gpt-5.6-sol", effort: "low"},
      developer: %{model: "gpt-5.6-sol", effort: "low"},
      reviewer: %{model: "gpt-5.6-terra", effort: "medium"},
      helpers: %{
        scout: %{model: "gpt-5.6-luna", effort: "low"},
        worker: %{model: "gpt-5.6-luna", effort: "medium"},
        expert: %{model: "gpt-5.6-sol", effort: "medium"}
      }
    }
  end

  defp contract do
    %{
      "scenarios" => [%{"id" => "scenario-a", "then" => "works"}],
      "risks" => [%{"id" => "risk-a", "scenario_ids" => ["scenario-a"]}]
    }
  end

  defp route_json do
    %{
      "name" => "codex",
      "harness" => "codex",
      "shaping" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
      "developer" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
      "reviewer" => %{"model" => "gpt-5.6-terra", "effort" => "medium"},
      "helpers" => %{
        "scout" => %{"model" => "gpt-5.6-luna", "effort" => "low"},
        "worker" => %{"model" => "gpt-5.6-luna", "effort" => "medium"},
        "expert" => %{"model" => "gpt-5.6-sol", "effort" => "medium"}
      }
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
