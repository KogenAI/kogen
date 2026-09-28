defmodule Kogen.ShapingAudit.StopHook do
  @moduledoc """
  `mix kogen.audit --stop-hook`: writes exactly one JSON Stop-hook decision
  to `KOGEN_SHAPING_HOOK_OUTPUT`, per `shaping-stop-hook`.

  A Codex helper thread's Stop event (its rollout's first line names a
  `subagent` source) and a non-shaper role or a present `.kogen/build.lock`
  are always allowed with no audit. Otherwise the package named by
  `KOGEN_SHAPING_INTENT_ID` is audited (`auditor: true`), and the decision
  follows its readiness, with three anti-trap escapes: the same revision
  stopped again (`stalled`), the ninth successive block on a chain
  (`block-limit`), and the auditor bound being reached (`auditor-bound`).
  No decision uses elapsed time except to record it.
  """

  alias Kogen.ShapingAudit.{Finding, Report}

  @lock_path ".kogen/build.lock"
  @reason_limit 16 * 1024
  @default_budget_ms 15 * 60 * 1000
  @complex_budget_ms 30 * 60 * 1000
  @block_limit 9

  @doc """
  Runs the Stop hook: reads the Stop-event JSON from `opts[:stdin]` (default
  standard input), decides, appends to `hook.jsonl`, updates
  `hook-state.json`, and writes the one decision to
  `env["KOGEN_SHAPING_HOOK_OUTPUT"]`.
  """
  @spec run(Path.t(), map(), keyword()) :: :ok
  def run(root, env, opts \\ []) do
    stdin = read_stdin(opts)
    output_path = Map.get(env, "KOGEN_SHAPING_HOOK_OUTPUT")

    decision = decide(root, env, opts, stdin)
    encoded = Jason.encode!(decision.json)

    if output_path do
      File.write!(output_path, encoded)
    end

    :ok
  end

  defp read_stdin(opts) do
    case Keyword.get(opts, :stdin) do
      nil -> IO.read(:stdio, :eof) |> normalize_stdin()
      value when is_function(value, 0) -> value.()
      value -> value
    end
  end

  defp normalize_stdin(:eof), do: ""
  defp normalize_stdin(data) when is_binary(data), do: data
  defp normalize_stdin(_other), do: ""

  defp decide(root, env, opts, stdin) do
    cond do
      helper_thread?(root, stdin) ->
        allow(%{"continue" => true}, "helper-thread")

      Map.get(env, "KOGEN_ROLE") != "shaper" ->
        allow(%{"continue" => true}, "role")

      File.exists?(Path.join(root, @lock_path)) ->
        allow(%{"continue" => true}, "locked")

      true ->
        decide_for_package(root, env, opts)
    end
  end

  defp allow(json, kind), do: %{json: json, kind: kind, log?: false}

  # --- Codex helper-thread detection --------------------------------------

  # The rollout's first line is its `session_meta`: a helper's
  # `payload.source` is `{"subagent": {"thread_spawn": ...}}`, the root's "cli".
  defp helper_thread?(root, stdin) do
    with {:ok, %{"transcript_path" => transcript_path}} <- decode(stdin),
         {:ok, contents} <- File.read(resolve(root, transcript_path)),
         [first_line | _rest] <- String.split(contents, "\n", parts: 2),
         {:ok, %{"payload" => %{"source" => %{"subagent" => %{"thread_spawn" => spawn}}}}}
         when is_map(spawn) <- decode(first_line) do
      true
    else
      _other -> false
    end
  end

  defp resolve(root, path) when is_binary(path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp resolve(_root, path), do: path

  defp decode(text) when is_binary(text) and text != "" do
    case Jason.decode(text) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> :error
    end
  end

  defp decode(_other), do: :error

  # --- The audited path ----------------------------------------------------

  defp decide_for_package(root, env, opts) do
    case find_slug(root, Map.get(env, "KOGEN_SHAPING_INTENT_ID")) do
      nil ->
        allow(%{"continue" => true}, "no-package")

      slug ->
        run_hook_audit(root, slug, env, opts)
    end
  end

  defp find_slug(_root, nil), do: nil

  defp find_slug(root, intent_id) do
    Enum.find_value(["drafts", "approved"], fn kind ->
      pattern = Path.join([root, ".kogen/intents", kind, "*", "intent.yaml"])
      pattern |> Path.wildcard() |> Enum.find_value(&slug_if_matches(&1, intent_id))
    end)
  end

  defp slug_if_matches(path, intent_id) do
    with {:ok, contents} <- File.read(path),
         true <- Regex.match?(~r/^id:\s*#{Regex.escape(intent_id)}\s*$/m, contents) do
      path |> Path.dirname() |> Path.basename()
    else
      _other -> nil
    end
  end

  defp run_hook_audit(root, slug, env, opts) do
    clock = Keyword.get(opts, :clock, fn -> DateTime.utc_now() end)

    state = %{
      __MODULE__.HookState.read(root, slug)
      | skip_key: Map.get(env, "KOGEN_SHAPING_SKIP_KEY")
    }

    # "Now" is read exactly twice per audited stop: before and after the audit.
    started_at = clock.()
    result = audit_safely(root, slug, env, opts)
    finished_at = clock.()

    case result do
      {:ok, report, path} ->
        try do
          finalize(%{
            root: root,
            slug: slug,
            env: env,
            state: state,
            report: report,
            report_path: path,
            audit_ms: millis_between(started_at, finished_at),
            now: finished_at
          })
        rescue
          error -> exception_decision(root, slug, state, finished_at, Exception.message(error))
        end

      {:error, reason} ->
        exception_decision(root, slug, state, finished_at, Kogen.ShapingAudit.error_text(reason))

      {:exception, message} ->
        exception_decision(root, slug, state, finished_at, message)
    end
  end

  defp audit_safely(root, slug, env, opts) do
    Kogen.ShapingAudit.audit(root, %{
      slug: slug,
      route: Map.get(env, "KOGEN_SHAPING_ROUTE"),
      auditor: true,
      env: env,
      opts: opts
    })
  rescue
    error -> {:exception, Exception.message(error)}
  end

  defp exception_decision(root, slug, state, now, message) do
    json = %{
      "continue" => true,
      "systemMessage" => "shaping audit error: #{message}; run mix kogen.audit #{slug}"
    }

    log_and_return(root, slug, state, %{
      json: json,
      kind: "error",
      log?: true,
      at: now,
      slug: slug,
      revision: nil,
      readiness: nil,
      report: nil,
      blocking: [],
      chain_blocks: state.chain_blocks,
      elapsed: nil
    })
  end

  defp finalize(%{root: root, slug: slug, env: env, state: state, report: report} = fin) do
    blocking = (report["findings"] || []) |> Enum.filter(&Finding.open_blocking?/1)
    blocking_ids = Enum.map(blocking, & &1["id"])
    auditor_layer = get_in(report, ["layers", "auditor"]) || %{}
    # The auditor bound is per HEAD: once used up, every later stop at that
    # HEAD is allowed; a new commit starts a fresh bound.
    bound_reached? =
      auditor_layer["bound_reached"] == true or
        (state.auditor_bound_reached and state.bound_head == report["head"])

    same_revision_blocked? = state.last_revision == report["revision"] and state.last_was_block

    {chain_start, chain_blocks, base_json, kind} =
      decide_outcome(fin, blocking, blocking_ids, bound_reached?, same_revision_blocked?)

    chain_ms =
      if is_integer(state.chain_start),
        do: max(DateTime.to_unix(fin.now, :millisecond) - state.chain_start, 0),
        else: 0

    complex? = complex?(root, report)
    budget_ms = if complex?, do: @complex_budget_ms, else: @default_budget_ms

    elapsed = %{
      "launch_ms" => launch_ms(env, fin.now),
      "chain_ms" => chain_ms,
      "audit_ms" => fin.audit_ms,
      "audit_total_ms" => state.audit_total_ms + fin.audit_ms,
      "budget_ms" => budget_ms,
      "complex" => complex?
    }

    Report.write(root, slug, Map.put(report, "elapsed", elapsed))

    json = maybe_presented(base_json, kind, report, fin.report_path, elapsed)

    new_state = %{
      state
      | chain_start: chain_start,
        chain_blocks: chain_blocks,
        last_revision: report["revision"],
        last_was_block: kind == "blocked",
        audit_total_ms: state.audit_total_ms + fin.audit_ms,
        auditor_bound_reached: bound_reached?,
        bound_head: report["head"]
    }

    log_and_return(root, slug, new_state, %{
      json: json,
      kind: kind,
      log?: true,
      at: fin.now,
      slug: slug,
      head: report["head"],
      route: report["route"],
      revision: report["revision"],
      readiness: report["readiness"],
      report: fin.report_path,
      blocking: blocking_ids,
      chain_blocks: chain_blocks,
      elapsed: elapsed
    })
  end

  defp decide_outcome(
         fin,
         _blocking,
         _blocking_ids,
         _bound_reached?,
         true = _same_revision_blocked?
       ) do
    # An allowed stop resets the chain clock, so the Shaper's own time never
    # counts; the block count stays, so the 8-block escape still applies.
    {nil, fin.state.chain_blocks, %{"continue" => true}, "stalled"}
  end

  defp decide_outcome(fin, blocking, blocking_ids, bound_reached?, false) do
    report = fin.report

    cond do
      report["readiness"] == "ready" or (report["readiness"] == "asking" and blocking == []) ->
        {nil, 0, %{"continue" => true}, ready_kind(report)}

      environment_only?(report) ->
        {nil, 0, environment_json(blocking, report), "environment"}

      bound_reached? ->
        {nil, fin.state.chain_blocks, auditor_bound_json(blocking_ids), "auditor-bound"}

      true ->
        block_or_escape(fin, blocking)
    end
  end

  defp environment_json(blocking, report) do
    unavailable =
      report["layers"]
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "unavailable"))
      |> Enum.map(& &1["reason"])
      |> Enum.reject(&is_nil/1)

    fixes =
      (Enum.map(blocking, & &1["message"]) ++ unavailable)
      |> Enum.uniq()
      |> Enum.join("; ")

    %{"continue" => true, "systemMessage" => "not ready: environment — #{fixes}"}
  end

  defp auditor_bound_json(blocking_ids) do
    %{
      "continue" => true,
      "systemMessage" =>
        "not ready: auditor bound reached; #{length(blocking_ids)} blocking findings remain (#{Enum.join(blocking_ids, ", ")})"
    }
  end

  defp block_or_escape(fin, blocking) do
    new_chain_start = fin.state.chain_start || DateTime.to_unix(fin.now, :millisecond)
    new_chain_blocks = fin.state.chain_blocks + 1

    if new_chain_blocks >= @block_limit do
      json = %{
        "continue" => true,
        "systemMessage" =>
          "not ready after #{new_chain_blocks - 1} blocks in this chain; allowing the stop to avoid a trap.\n" <>
            block_reason(blocking, fin.report, fin.report_path)
      }

      {nil, 0, json, "block-limit"}
    else
      json = %{
        "decision" => "block",
        "reason" => block_reason(blocking, fin.report, fin.report_path)
      }

      {new_chain_start, new_chain_blocks, json, "blocked"}
    end
  end

  defp ready_kind(%{"state" => "asking"}), do: "asking"
  defp ready_kind(_report), do: "ready"

  defp environment_only?(report) do
    findings = report["findings"] || []
    blocking = Enum.filter(findings, &Finding.open_blocking?/1)
    unavailable? = report["layers"] |> Map.values() |> Enum.any?(&(&1["status"] == "unavailable"))

    (blocking != [] and Enum.all?(blocking, &(&1["scope"] == "environment"))) or
      (blocking == [] and unavailable?)
  end

  defp maybe_presented(json, "ready", report, report_path, elapsed) do
    Map.put(json, "systemMessage", presented_summary(report, report_path, elapsed))
  end

  defp maybe_presented(json, _kind, _report, _report_path, _elapsed), do: json

  defp presented_summary(report, report_path, elapsed) do
    assumed = section_lines(report, "Assumed")
    undecided = section_lines(report, "Left undecided")

    not_audited = Enum.map(report["not_audited_by_auditor"] || [], &"- #{&1}")

    [
      "ready: #{report_path}",
      "elapsed: launch #{minutes(elapsed["launch_ms"])} min, chain #{minutes(elapsed["chain_ms"])} min, " <>
        "audit #{minutes(elapsed["audit_ms"])} min (total #{minutes(elapsed["audit_total_ms"])} min), " <>
        "budget #{minutes(elapsed["budget_ms"])} min",
      if(assumed != [], do: "Assumed:\n" <> Enum.join(assumed, "\n"), else: "Assumed: none"),
      if(undecided != [],
        do: "Left undecided:\n" <> Enum.join(undecided, "\n"),
        else: "Left undecided: none"
      ),
      if(not_audited != [],
        do: "Not audited by the auditor:\n" <> Enum.join(not_audited, "\n"),
        else: "Not audited by the auditor: none"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section_lines(%{"questions" => %{"sections" => sections}}, name) do
    Enum.map(Map.get(sections, name, []), fn entry ->
      text = entry["text"] || entry["title"]

      "- #{text}"
    end)
  end

  defp section_lines(_report, _name), do: []

  defp minutes(nil), do: "n/a"
  defp minutes(ms), do: :erlang.float_to_binary(ms / 60_000, decimals: 1)

  @doc false
  def block_reason(blocking, report_or_advisory, report_path) do
    advisory_count =
      if is_map(report_or_advisory),
        do: Enum.count(report_or_advisory["findings"] || [], &(&1["severity"] == "advisory")),
        else: report_or_advisory

    lines =
      Enum.map(blocking, fn finding ->
        "- #{finding["id"]} (route: #{finding["route"] || "none"}): #{finding["message"]}"
      end)

    suffix = ["advisory: #{advisory_count}", "report: #{report_path}"]
    build_reason(lines, suffix, @reason_limit)
  end

  defp build_reason(lines, suffix, limit) do
    base = Enum.join(["blocking findings:" | lines ++ suffix], "\n")
    if byte_size(base) <= limit, do: base, else: truncate_reason_lines(lines, suffix, limit)
  end

  defp truncate_reason_lines(lines, suffix, limit) do
    {kept, dropped} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, _dropped} ->
        remaining = length(lines) - length(acc) - 1
        marker = "- … #{max(remaining, 1)} more blocking findings in the report"

        candidate =
          Enum.join(
            ["blocking findings:" | acc ++ [line, marker | suffix]],
            "\n"
          )

        if byte_size(candidate) <= limit,
          do: {:cont, {acc ++ [line], remaining}},
          else: {:halt, {acc, length(lines) - length(acc)}}
      end)

    marker = "- … #{max(dropped, 1)} more blocking findings in the report"

    Enum.join(["blocking findings:" | kept ++ [marker | suffix]], "\n")
    |> trim_utf8(limit)
  end

  defp trim_utf8(text, limit) when byte_size(text) <= limit, do: text

  defp trim_utf8(text, limit) do
    candidate = binary_part(text, 0, limit)
    if String.valid?(candidate), do: candidate, else: trim_utf8(text, limit - 1)
  end

  defp complex?(root, report) do
    package_dir = Path.join(root, report["package"])

    scenarios =
      case File.read(Path.join(package_dir, "scenarios.yaml")) do
        {:ok, bytes} -> YamlElixir.read_from_string(bytes)
        _error -> :error
      end

    scenarios_list =
      case scenarios do
        {:ok, list} when is_list(list) -> list
        _other -> []
      end

    scenarios_count = length(scenarios_list)

    paid_targets_count =
      scenarios_list
      |> Enum.map(&get_in(&1, ["proof", "paid_target"]))
      |> Enum.reject(&(&1 in [nil, "none"]))
      |> Enum.uniq()
      |> length()

    evidence_count =
      package_dir
      |> Path.join("evidence/**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.count(&File.regular?/1)

    scenarios_count > 8 or paid_targets_count >= 2 or evidence_count > 10
  end

  defp launch_ms(env, now) do
    with launch_id when is_binary(launch_id) <- Map.get(env, "KOGEN_SHAPING_LAUNCH_ID"),
         {:ok, ms} <- uuidv7_ms(launch_id) do
      max(DateTime.to_unix(now, :millisecond) - ms, 0)
    else
      _other -> nil
    end
  end

  @doc "The millisecond timestamp encoded in a UUIDv7 string, or `:error`."
  @spec uuidv7_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  def uuidv7_ms(uuid) do
    if Regex.match?(
         ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
         uuid
       ) do
      hex = uuid |> String.replace("-", "") |> String.slice(0, 12)

      case Integer.parse(hex, 16) do
        {ms, ""} -> {:ok, ms}
        _other -> :error
      end
    else
      :error
    end
  end

  defp millis_between(%DateTime{} = a, %DateTime{} = b), do: DateTime.diff(b, a, :millisecond)

  # Only an allowed decision is cached for `stop_hook.sh`'s skip key: a block
  # is never replayed, so stopping again on the same revision reaches this
  # hook and takes the `stalled` escape instead of being blocked forever.
  defp log_and_return(root, slug, state, entry) do
    __MODULE__.HookState.append_log(root, slug, entry)

    cached =
      if entry.kind in ["blocked", "error"],
        do: %{state | decision: nil, skip_key: nil},
        else: %{state | decision: entry.json}

    __MODULE__.HookState.write(root, slug, cached)
    entry
  end

  defmodule HookState do
    @moduledoc false

    defstruct chain_start: nil,
              chain_blocks: 0,
              last_revision: nil,
              last_was_block: false,
              audit_total_ms: 0,
              auditor_bound_reached: false,
              bound_head: nil,
              skip_key: nil,
              decision: nil

    def read(root, slug) do
      path = Path.join(runtime_dir(root, slug), "hook-state.json")

      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, data} -> from_map(data)
            {:error, _reason} -> %__MODULE__{}
          end

        {:error, _reason} ->
          %__MODULE__{}
      end
    end

    @keys ~w(chain_start chain_blocks last_revision last_was_block audit_total_ms
             auditor_bound_reached bound_head skip_key decision)

    # An undecodable file, or one with an unknown, missing or mistyped field,
    # counts as absent: the hook re-audits and starts a new chain.
    defp from_map(%{} = data) do
      state = %__MODULE__{
        chain_start: data["chain_start"],
        chain_blocks: data["chain_blocks"],
        last_revision: data["last_revision"],
        last_was_block: data["last_was_block"],
        audit_total_ms: data["audit_total_ms"],
        auditor_bound_reached: data["auditor_bound_reached"],
        bound_head: data["bound_head"],
        skip_key: data["skip_key"],
        decision: data["decision"]
      }

      if Enum.sort(Map.keys(data)) == Enum.sort(@keys) and valid?(state),
        do: state,
        else: %__MODULE__{}
    end

    defp from_map(_data), do: %__MODULE__{}

    defp types do
      [
        chain_start: [&is_nil/1, &is_integer/1],
        chain_blocks: [&non_negative_integer?/1],
        last_revision: [&is_nil/1, &is_binary/1],
        last_was_block: [&is_boolean/1],
        audit_total_ms: [&is_integer/1],
        auditor_bound_reached: [&is_boolean/1],
        bound_head: [&is_nil/1, &is_binary/1],
        skip_key: [&is_nil/1, &is_binary/1],
        decision: [&is_nil/1, &is_map/1]
      ]
    end

    defp valid?(state) do
      Enum.all?(types(), fn {field, checks} ->
        Enum.any?(checks, & &1.(Map.fetch!(state, field)))
      end)
    end

    defp non_negative_integer?(value), do: is_integer(value) and value >= 0

    def write(root, slug, %__MODULE__{} = state) do
      dir = runtime_dir(root, slug)
      File.mkdir_p!(dir)
      path = Path.join(dir, "hook-state.json")

      json =
        Jason.encode!(%{
          "chain_start" => state.chain_start,
          "chain_blocks" => state.chain_blocks,
          "last_revision" => state.last_revision,
          "last_was_block" => state.last_was_block,
          "audit_total_ms" => state.audit_total_ms,
          "auditor_bound_reached" => state.auditor_bound_reached,
          "bound_head" => state.bound_head,
          "skip_key" => state.skip_key,
          "decision" => state.decision
        })

      tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
      File.write!(tmp, json)
      File.rename!(tmp, path)
    end

    def append_log(root, slug, entry) do
      dir = runtime_dir(root, slug)
      File.mkdir_p!(dir)
      path = Path.join(dir, "hook.jsonl")

      line =
        Jason.encode!(%{
          "at" => DateTime.to_iso8601(entry.at),
          "slug" => slug,
          "head" => Map.get(entry, :head),
          "route" => Map.get(entry, :route),
          "revision" => entry.revision,
          "kind" => entry.kind,
          "report" => entry.report,
          "readiness" => entry.readiness,
          "decision" => decision_word(entry.json),
          "blocking" => entry.blocking,
          "chain_blocks" => entry.chain_blocks,
          "elapsed" => entry.elapsed
        })

      File.write!(path, line <> "\n", [:append])
    end

    defp decision_word(%{"decision" => "block"}), do: "block"
    defp decision_word(_json), do: "allow"

    defp runtime_dir(root, slug), do: Path.join([root, ".kogen/runtime/shaping-audits", slug])
  end
end
