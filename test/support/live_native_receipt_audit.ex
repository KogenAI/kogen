defmodule Kogen.LiveNativeReceiptAudit do
  @moduledoc false
  alias Kogen.Build.VerificationPlan

  # `attempts` are the tracked attempt records; an attempt whose
  # `evidence_addendum` names a Reviewer session permits a second (confirming)
  # accept receipt for that session.
  def audit!(raw_log_dir, expected_sessions, reviewer_sessions \\ [], attempts \\ [])
      when is_map(expected_sessions) and is_list(reviewer_sessions) and is_list(attempts) do
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

    audit_reviewer_receipts!(raw_log_dir, reviewer_sessions, attempts)

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

  defp audit_reviewer_receipts!(_raw_log_dir, [], _attempts), do: :ok

  defp audit_reviewer_receipts!(raw_log_dir, reviewer_sessions, attempts) do
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
      addendum? = Enum.any?(attempts, &addendum_names?(&1, session_id))

      case {matching, addendum?} do
        {[receipt], _} ->
          require_reviewer_schema!(receipt)

        {[first, second], true} ->
          require_reviewer_schema!(first)
          require_reviewer_schema!(second)

          require!(
            second["verdict"] == "accept",
            "evidence addendum Reviewer receipt must be accept"
          )

          require!(
            second["attempt_token"] == first["attempt_token"] and
              second["candidate_id"] == first["candidate_id"],
            "evidence addendum must resume the Reviewer on the same attempt and Candidate"
          )

        _ ->
          raise ArgumentError,
                "expected one Reviewer receipt for session #{session_id} (two only with a matching evidence addendum), got #{length(matching)}"
      end
    end)
  end

  defp addendum_names?(attempt, session_id) when is_map(attempt),
    do: match?(%{"reviewer_session_id" => ^session_id}, attempt["evidence_addendum"])

  defp addendum_names?(_attempt, _session_id), do: false

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

  # Claude Code `-p --output-format stream-json`. Pinned 2.1.284 re-emits
  # system/init and result events each time background helper tasks finish
  # inside one `-p` process, so one capture holds one or more inits and results.
  # They must all share exactly one session_id, every result must be a
  # non-error success, and the stream must end on a result. Each result's usage
  # covers only its own segment (not cumulative), so the capture's usage is the
  # sum across results; taking only the final one would drop earlier work.
  defp claude_stream!(path, events) do
    name = Path.basename(path)
    starts = for event <- events, claude_init?(event), do: event["session_id"]
    results = Enum.filter(events, &(&1["type"] == "result"))

    require!(starts != [], "#{name} must bind exactly one native session")
    require!(results != [], "#{name} must contain one result event")
    require!(List.last(events)["type"] == "result", "#{name} must end with a result event")
    require!(Enum.all?(results, &is_map(&1["usage"])), "#{name} result needs a usage map")

    require!(
      Enum.all?(results, &(&1["subtype"] == "success" and &1["is_error"] != true)),
      "#{name} contains a failed provider event"
    )

    session_ids =
      for event <- events, is_binary(event["session_id"]), uniq: true, do: event["session_id"]

    require!(length(session_ids) == 1, "#{name} must bind exactly one native session")

    require!(
      Enum.all?(starts, &(&1 == hd(session_ids))),
      "#{name} must bind exactly one native session"
    )

    usage = results |> Enum.map(& &1["usage"]) |> Enum.reduce(&sum_usage(&2, &1))
    %{path: path, session_id: hd(session_ids), usage: usage}
  end

  defp sum_usage(left, right) do
    Map.merge(left, right, fn
      _key, a, b when is_number(a) and is_number(b) -> a + b
      _key, a, b when is_map(a) and is_map(b) -> sum_usage(a, b)
      _key, _a, b -> b
    end)
  end

  defp claude_init?(event), do: event["type"] == "system" and event["subtype"] == "init"

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
