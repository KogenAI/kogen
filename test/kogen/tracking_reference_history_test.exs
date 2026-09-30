defmodule Kogen.TrackingReferenceHistoryTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Tracking

  test "apply_verdict archives replaced Reviewer snapshots and retains exact record bytes" do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-reference-history-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route(), root)
    assert {:ok, state} = Tracking.start_attempt(state, "attempt-1", 0)

    attempt =
      state.record["attempts"]
      |> List.last()
      |> Map.put("candidate_id", "candidate-1")

    assert {:ok, state} = Tracking.update(state, Map.put(state.record, "attempts", [attempt]))

    first_bytes = state.bytes
    assert {:ok, first_record_snapshot} = Tracking.retain_record_version(state, first_bytes)

    assert {:ok, first_file_snapshot} =
             Tracking.retain_artifact(state, "fixed_file", "proof.txt", "proof v1")

    first_snapshots = %{
      Tracking.relative_path(state) => first_record_snapshot,
      "proof.txt" => first_file_snapshot
    }

    verdict = %{"verdict" => "accept", "dispositions" => [], "findings" => []}

    assert {:ok, state} =
             Tracking.apply_verdict(state, verdict, "reviewer-provisional", first_snapshots)

    second_bytes = state.bytes
    assert {:ok, second_record_snapshot} = Tracking.retain_record_version(state, second_bytes)

    assert {:ok, second_file_snapshot} =
             Tracking.retain_artifact(state, "fixed_file", "proof.txt", "proof v2")

    second_snapshots = %{
      Tracking.relative_path(state) => second_record_snapshot,
      "proof.txt" => second_file_snapshot
    }

    assert {:ok, state} =
             Tracking.apply_verdict(state, verdict, "reviewer-addendum", second_snapshots)

    attempt = List.last(state.record["attempts"])

    assert attempt["reviewer_reference_snapshots"] == second_snapshots

    assert attempt["reference_snapshot_history"] == [
             %{"candidate_id" => "candidate-1", "snapshots" => first_snapshots}
           ]

    assert File.read!(Path.expand(first_record_snapshot["sidecar"], root)) == first_bytes
    assert File.read!(Path.expand(first_file_snapshot["sidecar"], root)) == "proof v1"
    assert :ok = Tracking.verify_record_versions(state)
    assert :ok = Tracking.verify_artifacts(state)

    File.write!(Path.expand(first_file_snapshot["sidecar"], root), "changed")
    assert {:error, reason} = Tracking.verify_artifacts(state)
    assert reason =~ "retained artifact sidecar mutated"

    File.write!(Path.expand(first_file_snapshot["sidecar"], root), "proof v1")
    File.write!(Path.expand(first_record_snapshot["sidecar"], root), first_bytes <> "changed")
    assert {:error, reason} = Tracking.verify_record_versions(state)
    assert reason =~ "record version sidecar mutated"
  end

  test "malformed historical reference metadata is refused" do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-reference-history-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, state} = Tracking.new(intent(), contract(), approved_entries(), route(), root)
    assert {:ok, state} = Tracking.start_attempt(state, "attempt-1", 0)

    attempt =
      state.record["attempts"]
      |> List.last()
      |> Map.put("reference_snapshot_history", [
        %{"candidate_id" => "candidate-1", "snapshots" => %{"proof.txt" => %{}}}
      ])

    record = Map.put(state.record, "attempts", [attempt])
    assert {:error, reason} = Tracking.update(state, record)
    assert reason =~ "historical reference snapshots"
    assert :ok = Tracking.verify(state)

    invalid_state = %{state | record: record}
    assert {:error, reason} = Tracking.verify_artifacts(invalid_state)
    assert reason =~ "historical reference snapshots"
  end

  defp intent, do: %{"id" => "intent-history", "slug" => "history", "title" => "History"}

  defp contract do
    %{"scenarios" => [%{"id" => "scenario-a"}], "risks" => []}
  end

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

  defp approved_entries,
    do: [{"", :directory, 0o755}, {"intent.yaml", :regular, 0o644, "id: intent-history\n"}]
end
