defmodule Kogen.ShapingAudit.Auditor do
  @moduledoc """
  The blind, read-only Shaping auditor layer.

  Runs at most twice per slug and `HEAD` (route included): one fresh run on
  the first revision whose deterministic layer is clean, and a second,
  confirming run only on a later, changed revision when the first run was
  `ok` with at least one finding. It never runs while any deterministic
  finding is still open blocking, and never in `:asking` state. Jev's
  availability never gates it.

  The auditor is launched through `Kogen.Harness.open_auditor/2` and
  `Kogen.Harness.launch_auditor/4` only; this module never starts a harness
  executable itself. Its prompt is `priv/kogen/prompts/auditor.md` rendered
  with the bounded package and the scoped repository files, read from the
  materialization, never the checkout. Records live under
  `.kogen/runtime/shaping-audits/<slug>/auditor/<revision>-<route hash>.json`.
  """

  alias Kogen.ShapingAudit.{Finding, Materialization, Report}

  @prompt_path "priv/kogen/prompts/auditor.md"
  @budget_bytes 160_000
  @max_findings 50
  @max_summary 200
  @max_detail 1000
  @max_paths 10

  @doc """
  Runs (or reuses) the auditor layer for `ctx`. `deterministic_findings` is
  the deterministic layer's own findings (never Jev's). `opts`:

    * `:launch?` — when false, only existing records are reused; nothing is
      launched.
    * `:prior_failures` — the Intent's prior-failure list, inlined in the
      prompt.
  """
  def run(ctx, deterministic_findings, opts \\ []) do
    cond do
      ctx.state == :asking ->
        base_result("skipped", "the Shaping session is asking")

      Enum.any?(deterministic_findings, &Finding.open_blocking?/1) ->
        base_result("skipped", "an open blocking deterministic finding gates the auditor")

      true ->
        resolve(ctx, opts)
    end
  end

  defp resolve(ctx, opts) do
    config = ctx.config || %{route: ctx.route}

    case Kogen.Intent.auditor_config(config) do
      {:error, reason} -> base_result("unavailable", reason)
      {:ok, auditor} -> decide(ctx, auditor, opts)
    end
  end

  defp decide(ctx, auditor, opts) do
    counted =
      ctx
      |> load_records()
      |> Enum.filter(&(&1["counted"] != false))
      |> Enum.sort_by(&(&1["seq"] || 0))

    case counted do
      [] -> first_run(ctx, auditor, opts)
      [only] -> confirm_or_reuse(ctx, auditor, only, opts)
      list -> bound_reached(List.last(list))
    end
  end

  defp first_run(ctx, auditor, opts) do
    if Keyword.get(opts, :launch?, false) do
      launch_and_record(ctx, auditor, 1, opts)
    else
      base_result("not-run", "no prior auditor run to reuse, and launch is disabled")
    end
  end

  defp confirm_or_reuse(ctx, auditor, prior, opts) do
    cond do
      prior["revision"] == ctx.revision ->
        to_run_result(prior, false)

      prior["status"] == "ok" and prior["findings"] == [] ->
        reason = "ran once on HEAD #{ctx.head} with no findings; not re-run"

        prior
        |> Map.put("reason", reason)
        |> to_run_result(true)

      prior["status"] == "ok" ->
        if Keyword.get(opts, :launch?, false) do
          launch_and_record(ctx, auditor, 2, opts)
        else
          base_result("not-run", "a confirming run is due, and launch is disabled")
        end

      true ->
        prior
        |> Map.put("status", "unavailable")
        |> to_run_result(false, true)
    end
  end

  defp bound_reached(last), do: to_run_result(last, false, true)

  defp to_run_result(record, reused?, bound_reached? \\ false) do
    Map.merge(base_result(record["status"], record["reason"]), %{
      "findings" => record["findings"] || [],
      "elapsed_ms" => record["elapsed_ms"] || 0,
      "not_audited" => record["not_audited"] || [],
      "session_id" => record["session_id"],
      "launched" => record["launched"] == true,
      "dropped" => record["dropped"] || %{"findings" => 0, "fields" => 0, "paths" => 0},
      "reused" => reused?,
      "bound_reached" => bound_reached?
    })
  end

  defp base_result(status, reason) do
    %{
      "status" => status,
      "reason" => reason,
      "findings" => [],
      "launched" => false,
      "dropped" => %{"findings" => 0, "fields" => 0, "paths" => 0},
      "bound_reached" => false,
      "reused" => false,
      "elapsed_ms" => 0,
      "not_audited" => [],
      "session_id" => nil
    }
  end

  # -- launching and recording -----------------------------------------

  defp launch_and_record(ctx, auditor, seq, opts) do
    prior_failures = Keyword.get(opts, :prior_failures, [])
    {prompt, not_audited} = render_prompt(ctx, prior_failures)
    manifest = &default_manifest/1
    launcher = &default_launcher/3

    before_manifest = manifest.(ctx)
    started_at = System.monotonic_time(:millisecond)
    outcome = launcher.(ctx, auditor, prompt)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    record =
      case outcome do
        {:ok, %{session_id: session_id, message: message}} ->
          after_manifest = manifest.(ctx)

          if after_manifest == before_manifest do
            ok_or_unavailable(
              ctx,
              auditor,
              seq,
              session_id,
              message,
              elapsed_ms,
              not_audited,
              prompt
            )
          else
            rejected(
              ctx,
              auditor,
              seq,
              session_id,
              elapsed_ms,
              not_audited,
              prompt,
              manifest_diff(before_manifest, after_manifest)
            )
          end

        {:error, reason} ->
          launch_failure(ctx, auditor, reason, elapsed_ms, prompt)
      end

    persist(ctx, record)

    bound_reached? =
      record["counted"] != false and
        (seq == 2 or record["status"] in ["unavailable", "rejected"])

    to_run_result(record, false, bound_reached?)
  end

  defp ok_or_unavailable(ctx, auditor, seq, session_id, message, elapsed_ms, not_audited, prompt) do
    base = record_base(ctx, auditor, seq, session_id, elapsed_ms, not_audited, prompt)

    case parse_message(message) do
      {:ok, raw_findings} ->
        {findings, dropped} = build_findings(raw_findings, message)
        Map.merge(base, %{"status" => "ok", "findings" => findings, "dropped" => dropped})

      :error ->
        Map.merge(base, %{
          "status" => "unavailable",
          "reason" => "the auditor's final message carried no parseable findings JSON"
        })
    end
  end

  defp rejected(ctx, auditor, seq, session_id, elapsed_ms, not_audited, prompt, paths) do
    ctx
    |> record_base(auditor, seq, session_id, elapsed_ms, not_audited, prompt)
    |> Map.merge(%{
      "status" => "rejected",
      "reason" => "the auditor wrote to: #{Enum.join(paths, ", ")}"
    })
  end

  defp launch_failure(ctx, auditor, reason, elapsed_ms, prompt) do
    %{
      "schema_version" => 1,
      "route" => ctx.route,
      "harness" => auditor.harness,
      "model" => auditor.model,
      "effort" => auditor.effort,
      "session_id" => nil,
      "prompt_sha256" => sha256_hex(prompt),
      "revision" => ctx.revision,
      "head" => ctx.head,
      "status" => "unavailable",
      "counted" => false,
      "launched" => false,
      "elapsed_ms" => elapsed_ms,
      "findings" => [],
      "dropped" => %{"findings" => 0, "fields" => 0, "paths" => 0},
      "not_audited" => [],
      "reason" => "auditor launch failed: #{inspect(reason)}",
      "seq" => nil
    }
  end

  defp record_base(ctx, auditor, seq, session_id, elapsed_ms, not_audited, prompt) do
    %{
      "schema_version" => 1,
      "route" => ctx.route,
      "harness" => auditor.harness,
      "model" => auditor.model,
      "effort" => auditor.effort,
      "session_id" => session_id,
      "prompt_sha256" => sha256_hex(prompt),
      "revision" => ctx.revision,
      "head" => ctx.head,
      "counted" => true,
      "launched" => true,
      "elapsed_ms" => elapsed_ms,
      "findings" => [],
      "dropped" => %{"findings" => 0, "fields" => 0, "paths" => 0},
      "not_audited" => not_audited,
      "reason" => nil,
      "seq" => seq
    }
  end

  # Outside a Build launch the adapters set no `:cwd`; the auditor's working
  # directory must be the materialization, never the checkout, so the launch
  # context names it explicitly.
  defp default_launcher(ctx, auditor, prompt) do
    config = ctx.config || %{route: ctx.route}

    case Kogen.Harness.open_auditor(config, ctx.materialization) do
      {:ok, selection} ->
        try do
          context =
            selection
            |> Kogen.Harness.launch_context()
            |> Map.merge(%{cwd: ctx.materialization, output_schema: findings_schema()})

          Kogen.Harness.launch_auditor(prompt, auditor.model, auditor.effort, context)
        after
          Kogen.Harness.close(selection)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_manifest(ctx) do
    Map.merge(materialization_manifest(ctx), checkout_manifest(ctx))
  end

  defp materialization_manifest(ctx) do
    ctx.materialization
    |> Materialization.manifest()
    |> Map.new(fn {path, entry} -> {"materialization:" <> path, entry} end)
  end

  # The checkout's watched set: every tracked path (so an escape from the
  # materialization that touches the real checkout is caught even if it adds
  # or removes a tracked file) and the slug's report directory.
  defp checkout_manifest(ctx) do
    tracked = git_ls_files(ctx.root)
    report_dir = Report.runtime_dir(ctx.root, ctx.slug)

    tracked_manifest =
      Map.new(tracked, fn rel -> {"checkout:" <> rel, file_digest(Path.join(ctx.root, rel))} end)

    report_manifest =
      report_dir
      |> list_all_files()
      |> Map.new(fn abs -> {"report:" <> Path.relative_to(abs, ctx.root), file_digest(abs)} end)

    Map.merge(tracked_manifest, report_manifest)
  end

  defp git_ls_files(root) do
    case System.cmd("git", ["ls-files"], cd: root, env: [{"GIT_OPTIONAL_LOCKS", "0"}]) do
      {output, 0} -> output |> String.split("\n", trim: true)
      _ -> []
    end
  end

  defp list_all_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &list_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp list_entry(dir, name) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> list_all_files(path)
      {:ok, %File.Stat{type: :regular}} -> [path]
      _ -> []
    end
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, contents} -> sha256_hex(contents)
      {:error, _} -> nil
    end
  end

  defp manifest_diff(before_manifest, after_manifest) do
    before_set = MapSet.new(before_manifest)
    after_set = MapSet.new(after_manifest)

    before_set
    |> MapSet.symmetric_difference(after_set)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp findings_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["findings"],
      "properties" => %{
        "findings" => %{
          "type" => "array",
          "maxItems" => @max_findings,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["label", "summary", "detail", "paths"],
            "properties" => %{
              "label" => %{"type" => "string"},
              "summary" => %{"type" => "string", "maxLength" => @max_summary},
              "detail" => %{"type" => "string", "maxLength" => @max_detail},
              "paths" => %{
                "type" => "array",
                "maxItems" => @max_paths,
                "items" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end

  # -- records -----------------------------------------------------------

  @doc "The path an auditor record for `revision`/`route` lives at."
  def record_path(root, slug, revision, route) do
    hash = route |> sha256_hex() |> String.slice(0, 12)
    Path.join([Report.runtime_dir(root, slug), "auditor", "#{revision}-#{hash}.json"])
  end

  @doc "Every stored auditor record for `ctx`'s slug, route and HEAD."
  def load_records(ctx) do
    dir = Path.join(Report.runtime_dir(ctx.root, ctx.slug), "auditor")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&read_record(dir, &1))
        |> Enum.filter(&(&1["route"] == ctx.route and &1["head"] == ctx.head))

      {:error, _} ->
        []
    end
  end

  defp read_record(dir, name) do
    with {:ok, text} <- File.read(Path.join(dir, name)),
         {:ok, record} <- Jason.decode(text) do
      [record]
    else
      _ -> []
    end
  end

  defp persist(ctx, record) do
    path = record_path(ctx.root, ctx.slug, ctx.revision, ctx.route)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(record, pretty: true) <> "\n")
    File.rename!(tmp, path)
  end

  # -- parsing the auditor's final message --------------------------------

  @doc "Parses the auditor's final message: the last fenced JSON object, or a bare JSON message."
  def parse_message(message) when is_binary(message) do
    candidate =
      case Regex.scan(~r/```(?:json)?\s*\n(.*?)```/s, message) do
        [] -> message
        matches -> matches |> List.last() |> List.last()
      end

    with {:ok, %{"findings" => findings}} <- Jason.decode(String.trim(candidate)),
         true <- is_list(findings) do
      {:ok, findings}
    else
      _ -> :error
    end
  end

  def parse_message(_message), do: :error

  @doc "Builds bounded findings (`aud-<hash6>-<n>`) and the dropped counts from the raw JSON."
  def build_findings(raw_findings, message) do
    hash6 = message |> sha256_hex() |> String.slice(0, 6)
    total = length(raw_findings)
    kept_raw = Enum.take(raw_findings, @max_findings)
    dropped_findings = max(total - @max_findings, 0)

    {findings, field_drops, path_drops} =
      kept_raw
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0, 0}, fn {raw, n}, {acc, fd, pd} ->
        {finding, this_fd, this_pd} = build_finding(raw, hash6, n)
        {[finding | acc], fd + this_fd, pd + this_pd}
      end)

    findings = Enum.reverse(findings)
    dropped = %{"findings" => dropped_findings, "fields" => field_drops, "paths" => path_drops}

    findings =
      if dropped_findings > 0, do: findings ++ [dropped_finding(dropped_findings)], else: findings

    {findings, dropped}
  end

  defp build_finding(raw, hash6, n) when is_map(raw) do
    label = to_string(raw["label"] || "")
    {summary, fd1} = truncate(to_string(raw["summary"] || ""), @max_summary)
    {detail, fd2} = truncate(to_string(raw["detail"] || ""), @max_detail)
    {paths, pd} = truncate_list(List.wrap(raw["paths"]), @max_paths)
    message = [summary, detail] |> Enum.reject(&(&1 == "")) |> Enum.join(" — ")

    finding =
      "auditor-finding"
      |> Finding.new(Integer.to_string(n), %{
        "layer" => "auditor",
        "severity" => "blocking",
        "message" => message,
        "paths" => paths,
        "auditor_label" => label
      })
      |> Map.put("id", "aud-#{hash6}-#{n}")

    {finding, fd1 + fd2, pd}
  end

  defp build_finding(_raw, hash6, n) do
    build_finding(%{}, hash6, n)
  end

  defp dropped_finding(count) do
    Finding.new("auditor-findings-dropped", nil, %{
      "layer" => "auditor",
      "severity" => "blocking",
      "disputable" => false,
      "message" =>
        "the auditor's final message listed more findings than the #{@max_findings}-finding bound; #{count} finding(s) were dropped"
    })
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: {String.slice(text, 0, max), 1}, else: {text, 0}
  end

  defp truncate_list(list, max) do
    if length(list) > max, do: {Enum.take(list, max), 1}, else: {list, 0}
  end

  # -- the prompt ----------------------------------------------------------

  @doc "Renders `auditor.md` with the bounded package and scoped files; returns `{prompt, not_audited}`."
  def render_prompt(ctx, prior_failures) do
    header =
      @prompt_path
      |> File.read!()
      |> String.replace("{{package_rel}}", ctx.package_rel)
      |> String.replace("{{revision}}", ctx.revision)
      |> String.replace("{{head}}", ctx.head)
      |> String.replace("{{prior_failures}}", format_prior_failures(prior_failures))

    items = package_items(ctx) ++ scoped_items(ctx)
    budget = max(@budget_bytes - byte_size(header), 0)
    {included, not_audited} = fit(items, budget)

    body = Enum.map_join(included, "\n\n", &render_file/1)

    cuts_note =
      case not_audited do
        [] ->
          ""

        paths ->
          "\n\nNot audited by the auditor (left out at the byte budget): #{Enum.join(paths, ", ")}\n"
      end

    {header <> "\n\n" <> body <> cuts_note, not_audited}
  end

  defp fit(items, budget) do
    {included, not_audited, _remaining, _cut?} =
      Enum.reduce(items, {[], [], budget, false}, fn {label, content},
                                                     {inc, cut, remaining, cut?} ->
        size = byte_size(render_file({label, content}))

        cond do
          cut? -> {inc, cut ++ [label], remaining, true}
          size <= remaining -> {inc ++ [{label, content}], cut, remaining - size, false}
          true -> {inc, cut ++ [label], remaining, true}
        end
      end)

    {included, not_audited}
  end

  defp render_file({label, content}) do
    "=== FILE #{label} (#{byte_size(content)} bytes) ===\n#{content}"
  end

  defp format_prior_failures([]), do: "none recorded."

  defp format_prior_failures(list) do
    Enum.map_join(list, "; ", fn f -> "#{f["build_id"]}: #{f["signature"]} (#{f["detail"]})" end)
  end

  defp package_items(ctx) do
    [
      {"intent.yaml", trim_intent_yaml(Map.get(ctx.files, "intent.yaml"))},
      {"scenarios.yaml", Map.get(ctx.files, "scenarios.yaml")},
      {"risks.yaml", Map.get(ctx.files, "risks.yaml")},
      {"INTENT.md", Map.get(ctx.files, "INTENT.md")},
      {"questions.md", trim_questions_md(Map.get(ctx.files, "questions.md"))}
    ]
    |> Enum.filter(fn {_label, content} -> is_binary(content) end)
    |> Enum.map(fn {name, content} -> {Path.join(ctx.package_rel, name), content} end)
  end

  @reject_intent_keys ~w(revisions baseline_history shaping_continuations)

  defp trim_intent_yaml(nil), do: nil

  defp trim_intent_yaml(text) do
    {kept, _skipping} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {acc, skipping} ->
        case Regex.run(~r/^([A-Za-z0-9_]+):/, line) do
          [_, key] ->
            skip? =
              key in @reject_intent_keys or String.contains?(String.downcase(key), "approval")

            {if(skip?, do: acc, else: [line | acc]), skip?}

          nil ->
            {if(skipping, do: acc, else: [line | acc]), skipping}
        end
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end

  defp trim_questions_md(nil), do: nil

  defp trim_questions_md(text) do
    lines = String.split(text, "\n")

    case Enum.find_index(lines, &(&1 =~ ~r/^##\s+Dispositions\s*$/)) do
      nil ->
        text

      dispositions_at ->
        rest = Enum.drop(lines, dispositions_at + 1)

        case Enum.find_index(rest, &(&1 =~ ~r/^##\s+/)) do
          nil -> text
          offset -> lines |> Enum.take(dispositions_at + 1 + offset) |> Enum.join("\n")
        end
    end
  end

  defp scoped_items(ctx) do
    ctx
    |> scoped_paths()
    |> Enum.reduce([], fn rel, acc ->
      case File.read(Path.join(ctx.materialization, rel)) do
        {:ok, content} -> acc ++ [{rel, content}]
        _ -> acc
      end
    end)
  end

  defp scoped_paths(ctx) do
    affected = affected_paths(ctx.scenarios)
    guarded = expand_globs(guarded_paths(ctx.intent), ctx.materialization)

    (affected ++ guarded)
    |> Enum.uniq()
    |> Enum.reject(&String.starts_with?(&1, ctx.package_rel))
    |> Enum.sort()
  end

  defp affected_paths(scenarios) when is_list(scenarios) do
    Enum.flat_map(scenarios, fn scenario ->
      get_in(scenario, ["proof", "affected_paths"]) || []
    end)
  end

  defp affected_paths(_scenarios), do: []

  defp guarded_paths(%{"may_change_guarded_paths" => paths}) when is_list(paths), do: paths
  defp guarded_paths(_intent), do: []

  defp expand_globs(patterns, base) do
    Enum.flat_map(patterns, fn pattern ->
      if String.contains?(pattern, "*") do
        base
        |> Path.join(pattern)
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, base))
      else
        [pattern]
      end
    end)
  end

  defp sha256_hex(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end
