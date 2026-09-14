defmodule Kogen.BuildEvidenceTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Evidence

  test "resolves only the exact bound archive and rejects absence, corruption, identity, and versions" do
    root = Path.join(System.tmp_dir!(), "kogen-evidence-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, ".kogen/runtime/scenario-tracking/build-1"))
    record_path = ".kogen/runtime/scenario-tracking/build-1/record.json"

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-1",
      "status" => "accepted",
      "developer_session_id" => "developer-1",
      "reviewer_session" => "reviewer-1",
      "candidate_id" => "candidate-1"
    }

    record =
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "accepted",
        "intent" => %{"id" => "intent-1"},
        "attempts" => [attempt]
      })

    File.write!(Path.join(root, record_path), record)
    summary_path = Path.join(root, "build-summary.json")

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-1"},
      "build_id" => "build-1",
      "candidate_id" => "candidate-1",
      "developer_session_id" => "developer-1",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-1")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 1,
        "path" => record_path,
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    write_summary!(summary_path, summary)
    assert {:ok, %{"intent" => %{"id" => "intent-1"}}} = Evidence.resolve(summary_path, root)

    File.write!(Path.join(root, record_path), record <> " ")
    assert {:error, mismatch} = Evidence.resolve(summary_path, root)
    assert mismatch =~ "byte count mismatch"

    File.rm!(Path.join(root, record_path))
    assert {:error, missing} = Evidence.resolve(summary_path, root)
    assert missing =~ "unavailable"

    File.write!(Path.join(root, record_path), record)
    write_summary!(summary_path, put_in(summary, ["intent", "id"], "wrong"))
    assert {:error, identity} = Evidence.resolve(summary_path, root)
    assert identity =~ "identity mismatch"

    write_summary!(summary_path, Map.put(summary, "candidate_id", "wrong"))
    assert {:error, candidate} = Evidence.resolve(summary_path, root)
    assert candidate =~ "Candidate mismatch"

    write_summary!(summary_path, Map.put(summary, "build_id", "wrong"))
    assert {:error, build} = Evidence.resolve(summary_path, root)
    assert build =~ "Build identity mismatch"

    write_summary!(summary_path, Map.put(summary, "developer_session_id", "wrong"))
    assert {:error, session} = Evidence.resolve(summary_path, root)
    assert session =~ "Developer session mismatch"

    write_summary!(summary_path, Map.put(summary, "schema_version", 99))
    assert {:error, unsupported} = Evidence.resolve(summary_path, root)
    assert unsupported =~ "unsupported Build summary"
  end

  defp write_summary!(path, summary), do: File.write!(path, Jason.encode!(summary))
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
