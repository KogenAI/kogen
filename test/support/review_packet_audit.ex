defmodule Kogen.ReviewPacketAudit do
  @moduledoc false

  # Called only by Kogen.LiveReviewerReworkFixture. It never touches
  # test/support/live_rework_audit.ex, which live-shape-to-build also uses.
  #
  # Two independent jobs live here:
  #
  #   * canonicalizing the disposable fixture root and proving it sits outside
  #     the checkout and resolves to a logged-in Kogen Claude Code login scope
  #     (`fixture-outside-checkout`), before any provider dispatch;
  #   * auditing retained review-packet evidence from a finished nested Build
  #     (`live-packet-audit`): every packet's bytes and bindings, a Reviewer
  #     tool call that names the packet path, the accepting verdict's
  #     Candidate citation, and the record's own self-reference hygiene.

  import ExUnit.Assertions

  @packet_byte_limit 65_536

  ## Canonical, outside-checkout fixture root -------------------------------

  @doc """
  Resolves `path` to its canonical, symlink-free absolute form (creating it
  first if it does not yet exist). On macOS this turns a `/tmp/...` or
  `/var/folders/...` alias into its `/private/...` target.
  """
  def canonical_path!(path) do
    File.mkdir_p!(path)

    case System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "--", path]) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "could not resolve canonical path for #{path} (#{status}): #{out}"
    end
  end

  @doc """
  Asserts that the canonical form of `root` lies strictly outside the
  canonical form of `checkout`. Returns the canonical `root`. This is a real
  assertion, not a comment: a fixture root under the checkout raises.
  """
  def assert_outside_checkout!(root, checkout) do
    canonical_root = canonical_path!(root)
    canonical_checkout = canonical_path!(checkout)

    inside? =
      canonical_root == canonical_checkout or
        String.starts_with?(canonical_root, canonical_checkout <> "/")

    refute inside?,
           "fixture root #{canonical_root} must lie outside the checkout #{canonical_checkout}"

    canonical_root
  end

  @doc """
  Asserts that `fixture_root` resolves, through Kogen's own scope selection,
  to a logged-in Kogen Claude Code login scope. Fails before any provider
  dispatch otherwise. Delegates to the existing public
  `Kogen.ClaudeCode.open/2` readiness check; it invents no login logic here.
  """
  def assert_logged_in!(fixture_root) do
    case Kogen.ClaudeCode.open(%{harness: "claude"}, fixture_root) do
      {:ok, selection} ->
        Kogen.ClaudeCode.close(selection)
        :ok

      {:error, reason} ->
        flunk(
          "fixture root #{fixture_root} does not resolve to a logged-in Kogen Claude Code scope: #{reason}"
        )
    end
  end

  ## Evidence retention ------------------------------------------------------

  @doc """
  Copies the nested Build's `.kogen/runtime/scenario-tracking` tree (every
  record.json, its record-versions/*.json sidecars and review-packets/*.json
  packets) and the whole `.kogen/intents/complete/<slug>` package into
  `log_dir`, so the packet audit -- and any later inspection -- can run from
  files that survive the fixture's removal.
  """
  def retain_evidence!(fixture, log_dir, slug) do
    tracking_source = Path.join(fixture, ".kogen/runtime/scenario-tracking")
    tracking_destination = Path.join(log_dir, "scenario-tracking")

    build_ids =
      tracking_source
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)

    for build_id <- build_ids do
      copy_tree!(Path.join(tracking_source, build_id), Path.join(tracking_destination, build_id))
    end

    complete_source = Path.join(fixture, ".kogen/intents/complete/#{slug}")
    complete_destination = Path.join(log_dir, "complete/#{slug}")

    if File.dir?(complete_source), do: copy_tree!(complete_source, complete_destination)

    %{
      scenario_tracking_dir: tracking_destination,
      complete_dir: complete_destination,
      build_ids: build_ids
    }
  end

  defp copy_tree!(source, destination) do
    File.mkdir_p!(Path.dirname(destination))
    File.rm_rf!(destination)
    File.cp_r!(source, destination)
  end

  ## Packet audit -------------------------------------------------------------

  @doc """
  Audits retained review-packet evidence under `log_dir` (as produced by
  `retain_evidence!/3`) for `build_id`, using `raw_log_dir` for the Reviewers'
  retained raw provider streams (default: `log_dir/build-raw-streams`).

  `candidate_source` lets the accepting verdict's Candidate-file citation be
  checked either against the fixture's still-live git object database
  (`{:git, fixture, candidate_id}`, used by the live fixture before it removes
  the fixture) or against a plain retained directory (`{:dir, path}`, used by
  offline synthetic tests). Writes `review-packet-audit.json` into `log_dir`
  and returns the summary.
  """
  def audit!(log_dir, build_id, candidate_source, options \\ []) do
    raw_log_dir = Keyword.get(options, :raw_log_dir, Path.join(log_dir, "build-raw-streams"))

    record_path =
      Path.join([log_dir, "scenario-tracking", build_id, "record.json"])

    require_file!(record_path, "retained nested record")
    record = json_file!(record_path, "retained nested record")
    attempts = record["attempts"] || []
    assert is_list(attempts) and attempts != [], "retained nested record has no attempts"

    record_relative_path = ".kogen/runtime/scenario-tracking/#{build_id}/record.json"

    packet_results =
      for attempt <- attempts, is_map(attempt["review_packet"]) do
        verify_packet!(log_dir, build_id, attempt)
      end

    tool_call_results =
      for attempt <- attempts,
          is_map(attempt["review_packet"]),
          is_binary(attempt["reviewer_session"]) do
        verify_reviewer_tool_call!(raw_log_dir, build_id, attempt)
      end

    verdict_citation = verify_candidate_citation!(attempts, candidate_source)

    for attempt <- attempts, do: refute_inline_self_reference!(attempt, record_relative_path)

    summary = %{
      "schema_version" => 1,
      "build_id" => build_id,
      "record_path" => record_relative_path,
      "packets" => packet_results,
      "reviewer_tool_calls" => tool_call_results,
      "candidate_citation" => verdict_citation,
      "reviews" =>
        Enum.map(
          tool_call_results,
          &Map.take(&1, ["reviewer_session", "elapsed_seconds", "elapsed_source"])
        )
    }

    File.write!(
      Path.join(log_dir, "review-packet-audit.json"),
      Jason.encode!(summary, pretty: true) <> "\n"
    )

    summary
  end

  defp verify_packet!(log_dir, build_id, attempt) do
    packet = attempt["review_packet"]

    expected_relative =
      ".kogen/runtime/scenario-tracking/#{build_id}/review-packets/#{attempt["number"]}.json"

    assert packet["path"] == expected_relative,
           "attempt #{inspect(attempt["number"])} review_packet path must follow the interface layout"

    absolute = resolve_retained!(log_dir, packet["path"])
    require_file!(absolute, "review packet for attempt #{inspect(attempt["number"])}")

    bytes = File.read!(absolute)
    byte_count = byte_size(bytes)

    assert byte_count <= @packet_byte_limit,
           "review packet #{packet["path"]} is #{byte_count} bytes, over the #{@packet_byte_limit} bound"

    assert byte_count == packet["byte_count"],
           "review packet #{packet["path"]} byte count does not match the record"

    packet_json =
      case Jason.decode(bytes) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> flunk("review packet #{packet["path"]} does not parse as a JSON object")
      end

    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert digest == packet["sha256"],
           "review packet #{packet["path"]} sha256 does not match the record"

    assert packet_json["attempt_token"] == packet["attempt_token"] and
             packet_json["attempt_token"] == attempt["attempt_token"],
           "review packet #{packet["path"]} attempt_token must match the record and the attempt"

    assert packet_json["candidate_id"] == packet["candidate_id"] and
             packet_json["candidate_id"] == attempt["candidate_id"],
           "review packet #{packet["path"]} candidate_id must match the record and the attempt"

    assert packet_json["attempt_number"] == attempt["number"],
           "review packet #{packet["path"]} attempt_number must match the attempt"

    %{
      "attempt_number" => attempt["number"],
      "path" => packet["path"],
      "byte_count" => byte_count,
      "sha256" => digest
    }
  end

  defp verify_reviewer_tool_call!(raw_log_dir, build_id, attempt) do
    reviewer_session = attempt["reviewer_session"]
    packet = attempt["review_packet"]
    full_needle = packet["path"]
    suffix_needle = "#{build_id}/review-packets/#{attempt["number"]}.json"

    stream_path = find_stream_for_session!(raw_log_dir, reviewer_session)
    events = json_events(stream_path)

    tool_call_texts = Enum.flat_map(events, &tool_call_texts/1)

    names_packet? =
      Enum.any?(tool_call_texts, fn text ->
        String.contains?(text, full_needle) or String.contains?(text, suffix_needle)
      end)

    assert names_packet?,
           "Reviewer #{reviewer_session}'s retained raw stream has no tool call naming #{packet["path"]}"

    {elapsed_seconds, elapsed_source} = elapsed_seconds(events)

    %{
      "reviewer_session" => reviewer_session,
      "attempt_number" => attempt["number"],
      "stream" => Path.basename(stream_path),
      "elapsed_seconds" => elapsed_seconds,
      "elapsed_source" => elapsed_source
    }
  end

  defp find_stream_for_session!(raw_log_dir, session_id) do
    matches =
      raw_log_dir
      |> Path.join("raw-stream-*.jsonl")
      |> Path.wildcard()
      |> Enum.filter(fn path -> Enum.any?(json_events(path), &stream_binds?(&1, session_id)) end)

    case matches do
      [single] ->
        single

      [] ->
        flunk("no retained raw provider stream binds Reviewer session #{session_id}")

      _ ->
        flunk("more than one retained raw provider stream binds Reviewer session #{session_id}")
    end
  end

  # Claude Code binds a capture with its `system`/`init` event; Codex with
  # `thread.started`.
  defp stream_binds?(%{"type" => "system", "subtype" => "init", "session_id" => id}, session),
    do: id == session

  defp stream_binds?(%{"type" => "thread.started", "thread_id" => id}, session), do: id == session
  defp stream_binds?(_event, _session), do: false

  # Only tool calls -- Claude Code `assistant` messages carrying a `tool_use`
  # content item, or a Codex `item.completed` tool item (not a message,
  # reasoning, plan or error item) -- are collected. Prompt text, reasoning
  # and tool results never satisfy the check.
  defp tool_call_texts(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    for %{"type" => "tool_use"} = item <- content,
        do: Jason.encode!(Map.get(item, "input", %{}))
  end

  defp tool_call_texts(%{"type" => "item.completed", "item" => %{"type" => type} = item})
       when type not in ["agent_message", "reasoning", "todo_list", "error"] do
    [Jason.encode!(Map.drop(item, ["type", "id"]))]
  end

  defp tool_call_texts(_event), do: []

  defp elapsed_seconds(events) do
    result = Enum.find(events, &(&1["type"] == "result" and is_number(&1["duration_ms"])))

    case result do
      %{"duration_ms" => ms} -> {ms / 1000.0, "duration_ms"}
      _ -> {nil, "unavailable"}
    end
  end

  defp verify_candidate_citation!(attempts, candidate_source) do
    accepting = List.last(attempts)
    verdict = accepting["verdict"] || %{}

    paths =
      (evidence_paths(verdict["scenarios"]) ++ evidence_paths(verdict["dispositions"]))
      |> Enum.uniq()
      |> Enum.reject(&(is_nil(&1) or String.starts_with?(&1, ".kogen/")))

    cited = Enum.find(paths, &candidate_has_file?(candidate_source, &1))

    assert is_binary(cited),
           "accepting Reviewer's verdict must cite at least one Candidate file outside .kogen/"

    %{"attempt_number" => accepting["number"], "path" => cited}
  end

  defp evidence_paths(items) when is_list(items) do
    for item <- items,
        is_map(item),
        evidence <- List.wrap(item["evidence"]),
        is_map(evidence),
        is_binary(evidence["path"]),
        do: evidence["path"]
  end

  defp evidence_paths(_), do: []

  @doc "Whether `path` is a file in the Candidate identified by `candidate_source`."
  def candidate_has_file?({:git, fixture, candidate_id}, path) do
    case System.cmd("git", ["cat-file", "-e", "#{candidate_id}:#{path}"],
           cd: fixture,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  def candidate_has_file?({:dir, dir}, path), do: File.regular?(Path.join(dir, path))

  defp refute_inline_self_reference!(attempt, record_relative_path) do
    for key <- [
          "developer_reference_snapshots",
          "reviewer_reference_snapshots",
          "reference_snapshots"
        ] do
      snapshots = attempt[key] || %{}
      entry = if is_map(snapshots), do: snapshots[record_relative_path]

      refute is_map(entry) and Map.has_key?(entry, "content_base64") and
               not is_nil(entry["content_base64"]),
             "attempt #{inspect(attempt["number"])} #{key} must not inline the record's own bytes"
    end
  end

  defp resolve_retained!(log_dir, ".kogen/runtime/" <> rest), do: Path.join(log_dir, rest)

  defp resolve_retained!(_log_dir, other),
    do: flunk("unexpected checkout-relative record path: #{other}")

  defp json_events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)
  end

  defp json_file!(path, label) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> flunk("#{label} contains malformed JSON")
    end
  end

  defp require_file!(path, label), do: assert(File.regular?(path), "missing #{label}: #{path}")
end
