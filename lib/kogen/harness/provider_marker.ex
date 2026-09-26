defmodule Kogen.Harness.ProviderMarker do
  @moduledoc """
  Recognizes provider markers (usage/session limit, overload/capacity, 5xx) in
  harness output, so a `provider` failure class can never cover a failure a
  Candidate can cause.

  There is no whole-output regex: a bare `5\\d\\d` pattern matches timestamps
  and byte counts in ordinary receipts (evidence/probe-signals). Instead this
  module decodes every line of `text` as JSON independently (a paid target's
  make log embeds nested harness streams; the marker can be anywhere, not
  just at the very end) and classifies only structured fields the harness
  adapters themselves emit:

    * Claude Code: a `result` event (`is_error: true`) whose
      `api_error_status`/`apiErrorStatus` is `429` or `5xx`, or whose `error`
      is `"rate_limit"`. `subtype` is never read: it is `"success"` even on a
      real 429 (BE-N9cRQ).
    * Codex: `codex_error_info` `"server_overloaded"` or
      `"usage_limit_exceeded"` (the rollout form), or an `error`/`turn.failed`
      event whose message says "at capacity", "overloaded" or a rate limit
      (the exec/stream-json form, which lacks `codex_error_info`).

  A timeout (Kogen's own harness turn timeout, exit 124, or an ExUnit
  timeout) never carries any of these structured fields, so it is never
  classified as a provider marker; it stays a paid failure.
  """

  @marker_bound 2_000

  @doc """
  Classifies `text`. Returns `nil` when no provider marker is found, or a map
  with `"class" => "provider"`, `"kind" => "usage_limit" | "overload" |
  "server_error"`, `"retry" => boolean` and `"marker"` (the classifying line,
  bounded to #{@marker_bound} characters).

  `retry` is `true` for overload, capacity and 5xx failures (retried once);
  `false` for a usage or session limit (never retried, because waiting out a
  limit is a non-goal).
  """
  def classify(text) when is_binary(text) do
    text
    |> json_lines()
    |> Enum.find_value(&classify_line/1)
  end

  def classify(_text), do: nil

  defp json_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      case Jason.decode(trimmed) do
        {:ok, json} when is_map(json) -> [{trimmed, json}]
        _ -> []
      end
    end)
  end

  defp classify_line({line, json}),
    do: claude_marker(json, line) || codex_marker(json, line) || envelope_marker(json, line)

  # Codex rollout events nest the terminal payload one level deeper
  # (`{"type":"event_msg","payload":{"type":"task_complete","error":{...}}}`);
  # unwrap and classify the payload with the same rules, still bounded to
  # this one decoded line, never a whole-output scan.
  defp envelope_marker(%{"payload" => payload}, line) when is_map(payload),
    do: codex_marker(payload, line)

  defp envelope_marker(_json, _line), do: nil

  # Claude Code's terminal `result` event. `subtype` is deliberately never
  # inspected: it reads "success" even when `is_error: true` (BE-N9cRQ).
  defp claude_marker(%{"is_error" => true} = json, line) do
    status = json["api_error_status"] || json["apiErrorStatus"]

    cond do
      status == 429 -> marker("usage_limit", false, line)
      is_integer(status) and status in 500..599 -> marker("server_error", true, line)
      json["error"] == "rate_limit" -> marker("usage_limit", false, line)
      true -> nil
    end
  end

  defp claude_marker(_json, _line), do: nil

  # Codex's structured field (rollout form), directly or nested under
  # `"error"` (the exec/stream-json `turn.failed` event nests it there).
  defp codex_marker(%{"codex_error_info" => info}, line), do: codex_error_info_marker(info, line)

  defp codex_marker(%{"error" => %{"codex_error_info" => info}}, line),
    do: codex_error_info_marker(info, line)

  # Codex's freeform text form: an `error` or `turn.failed` event whose
  # message says "at capacity", "overloaded" or a rate limit. This is the
  # only fallback, and it is scoped to these two event types, never the
  # whole blob (hJeqtBSg: the exec/stream-json form never carries
  # `codex_error_info`).
  defp codex_marker(%{"type" => type, "message" => message}, line)
       when type in ["error", "turn.failed"] and is_binary(message),
       do: codex_text_marker(message, line)

  defp codex_marker(%{"type" => "turn.failed", "error" => %{"message" => message}}, line)
       when is_binary(message),
       do: codex_text_marker(message, line)

  defp codex_marker(_json, _line), do: nil

  defp codex_error_info_marker("server_overloaded", line), do: marker("overload", true, line)

  defp codex_error_info_marker("usage_limit_exceeded", line),
    do: marker("usage_limit", false, line)

  defp codex_error_info_marker(_info, _line), do: nil

  defp codex_text_marker(message, line) do
    cond do
      message =~ ~r/at capacity/i or message =~ ~r/overloaded/i ->
        marker("overload", true, line)

      message =~ ~r/rate.?limit|usage limit/i ->
        marker("usage_limit", false, line)

      true ->
        nil
    end
  end

  defp marker(kind, retry, line) do
    %{
      "class" => "provider",
      "kind" => kind,
      "retry" => retry,
      # A tail slice, not a head slice: the classifying fields (Claude's
      # `is_error`/`api_error_status`, Codex's `codex_error_info`) can sit
      # after a large payload (permission denials, tool output) earlier in
      # the same decoded line.
      "marker" => String.slice(line, -@marker_bound, @marker_bound)
    }
  end
end
