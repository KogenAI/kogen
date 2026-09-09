defmodule Kogen.CheckSettlementTest do
  @moduledoc "Tests the Verification Record settlement rule against one Candidate and session."

  @candidate_id "candidate-abc123"
  @session_id "session-xyz789"

  @settlement_cases [
    %{
      case: "different candidate id",
      record: %{
        "candidate" => "some-other-candidate",
        "status" => "passed",
        "target" => "check",
        "session_id" => @session_id,
        "exit_code" => 0
      },
      settles: false
    },
    %{
      case: "different session id",
      record: %{
        "candidate" => @candidate_id,
        "status" => "passed",
        "target" => "check",
        "session_id" => "some-other-session",
        "exit_code" => 0
      },
      settles: false
    },
    %{
      case: "failed status",
      record: %{
        "candidate" => @candidate_id,
        "status" => "failed",
        "target" => "check",
        "session_id" => @session_id,
        "exit_code" => 1
      },
      settles: false
    },
    %{
      case: "wrong target",
      record: %{
        "candidate" => @candidate_id,
        "status" => "passed",
        "target" => "test",
        "session_id" => @session_id,
        "exit_code" => 0
      },
      settles: false
    },
    %{
      case: "nonzero check exit",
      record: %{
        "candidate" => @candidate_id,
        "status" => "passed",
        "target" => "check",
        "session_id" => @session_id,
        "exit_code" => 1
      },
      settles: false
    },
    %{
      case: "missing Verification Record",
      record: nil,
      settles: false,
      failure_reason: "no Verification Record was written"
    },
    %{
      case: "matching passed check",
      record: %{
        "candidate" => @candidate_id,
        "status" => "passed",
        "target" => "check",
        "session_id" => @session_id,
        "exit_code" => 0
      },
      settles: true
    }
  ]

  use ExUnit.Case, async: true, parameterize: @settlement_cases

  alias Kogen.Check

  test "Verification Record settles only its matching Candidate and session",
       %{
         record: record,
         settles: settles
       } = settlement_case do
    in_tmp_dir(fn dir ->
      if is_nil(record), do: refute(File.exists?(Path.join(dir, Check.record_path())))
      if record, do: write_record(dir, record)

      if settles do
        assert Check.settled_pass?(@candidate_id, @session_id, dir)
      else
        refute Check.settled_pass?(@candidate_id, @session_id, dir)
      end

      if failure_reason = Map.get(settlement_case, :failure_reason) do
        assert Check.settlement_failure_reason(@candidate_id, @session_id, dir) == failure_reason
      end
    end)
  end

  defp write_record(dir, record) do
    path = Path.join(dir, Check.record_path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record))
  end

  defp in_tmp_dir(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-check-settlement-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    fun.(dir)
  end
end
