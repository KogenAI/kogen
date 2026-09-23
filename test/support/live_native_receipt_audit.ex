defmodule Kogen.LiveNativeReceiptAudit do
  @moduledoc false
  alias Kogen.Build.VerificationPlan

  def audit!(raw_log_dir, expected_sessions, reviewer_sessions \\ [])
      when is_map(expected_sessions) and is_list(reviewer_sessions) do
    VerificationPlan.trace("Kogen.LiveNativeReceiptAudit.audit!")

    streams =
      raw_log_dir
      |> Path.join("raw-stream-*.jsonl")
      |> Path.wildcard()
      |> Enum.map(&stream!/1)

    Enum.each(expected_sessions, fn {session_id, expected_count} ->
      require!(is_binary(session_id) and session_id != "", "native receipt needs a session id")

      require!(
        is_integer(expected_count) and expected_count > 0,
        "native receipt count must be positive"
      )

      matching = Enum.filter(streams, &(&1.session_id == session_id))

      require!(
        length(matching) == expected_count,
        "expected #{expected_count} completed native capture(s) for session #{session_id}, got #{length(matching)}"
      )
    end)

    audit_reviewer_receipts!(raw_log_dir, reviewer_sessions)

    %{
      provider_invocations: length(streams),
      required_invocations: Enum.sum(Map.values(expected_sessions)),
      usage_by_capture:
        Enum.map(
          streams,
          &%{path: Path.basename(&1.path), session_id: &1.session_id, usage: &1.usage}
        ),
      accounting_note:
        "Usage maps are retained per capture because resumed native counters can include prior work; cached input is a subset and missing usage is unavailable, never zero."
    }
  end

  defp audit_reviewer_receipts!(_raw_log_dir, []), do: :ok

  defp audit_reviewer_receipts!(raw_log_dir, reviewer_sessions) do
    path = Path.join(raw_log_dir, "reviewer-verdicts.jsonl")
    require!(File.regular?(path), "missing native Reviewer receipt log")

    receipts =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Jason.decode(line) do
          {:ok, receipt} when is_map(receipt) -> receipt
          _ -> raise ArgumentError, "native Reviewer receipt log contains malformed JSON"
        end
      end)

    Enum.each(reviewer_sessions, fn session_id ->
      matching = Enum.filter(receipts, &(&1["session_id"] == session_id))
      require!(length(matching) == 1, "expected one Reviewer receipt for session #{session_id}")
      [receipt] = matching
      require_reviewer_schema!(receipt)
    end)
  end

  defp require_reviewer_schema!(receipt) do
    require!(nonblank?(receipt["candidate_id"]), "Reviewer receipt needs a candidate binding")
    require!(nonblank?(receipt["attempt_token"]), "Reviewer receipt needs an attempt binding")

    require!(
      receipt["verdict"] in ["accept", "rework"],
      "Reviewer receipt has an invalid verdict"
    )

    require!(is_list(receipt["scenarios"]), "Reviewer receipt needs scenarios")
    require!(is_list(receipt["dispositions"]), "Reviewer receipt needs dispositions")
    require!(is_list(receipt["findings"]), "Reviewer receipt needs findings")
  end

  defp nonblank?(value), do: is_binary(value) and value != ""

  defp stream!(path) do
    events =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> [event]
          _ -> []
        end
      end)

    if Enum.any?(events, &claude_init?/1),
      do: claude_stream!(path, events),
      else: codex_stream!(path, events)
  end

  defp codex_stream!(path, events) do
    starts = for %{"type" => "thread.started", "thread_id" => id} <- events, do: id
    completions = Enum.filter(events, &(&1["type"] == "turn.completed"))

    require!(length(starts) == 1, "#{Path.basename(path)} must bind exactly one native session")

    require!(
      length(completions) == 1,
      "#{Path.basename(path)} must contain one turn.completed event"
    )

    [completion] = completions

    require!(
      is_map(completion["usage"]),
      "#{Path.basename(path)} turn.completed needs a usage map"
    )

    failed =
      Enum.find(events, fn event ->
        type = event["type"]
        is_binary(type) and (String.ends_with?(type, ".failed") or type == "error")
      end)

    require!(is_nil(failed), "#{Path.basename(path)} contains a failed provider event")
    %{path: path, session_id: hd(starts), usage: completion["usage"]}
  end

  # Claude Code `-p --output-format stream-json`: one init binds the session
  # and exactly one successful result settles the turn with its usage.
  defp claude_stream!(path, events) do
    starts = for event <- events, claude_init?(event), do: event["session_id"]
    results = Enum.filter(events, &(&1["type"] == "result"))

    require!(length(starts) == 1, "#{Path.basename(path)} must bind exactly one native session")
    require!(length(results) == 1, "#{Path.basename(path)} must contain one result event")
    [result] = results
    require!(is_map(result["usage"]), "#{Path.basename(path)} result needs a usage map")

    require!(
      result["subtype"] == "success" and result["is_error"] != true,
      "#{Path.basename(path)} contains a failed provider event"
    )

    require!(
      Enum.all?(events, &(not is_binary(&1["session_id"]) or &1["session_id"] == hd(starts))),
      "#{Path.basename(path)} must bind exactly one native session"
    )

    %{path: path, session_id: hd(starts), usage: result["usage"]}
  end

  defp claude_init?(event), do: event["type"] == "system" and event["subtype"] == "init"

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
