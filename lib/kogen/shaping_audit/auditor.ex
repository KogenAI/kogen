defmodule Kogen.ShapingAudit.Auditor do
  @moduledoc """
  The blind, read-only Shaping auditor layer.

  Runs at most twice per slug, `HEAD` and route during ordinary Shaping. The
  second run is fresh when the package revision changes, even if the first
  run found nothing. A prior result confirms only the exact package revision,
  `HEAD` and route recorded with it. An external `--confirm` request can use
  one additional counted run for that slug/`HEAD`/route. It never runs while
  any deterministic finding is still open blocking, and never in `:asking`
  state. Jev's availability never gates it.

  The auditor is launched through `Kogen.Harness.open_auditor/2` and
  `Kogen.Harness.launch_auditor/4` only; this module never starts a harness
  executable itself. Its prompt is `priv/kogen/prompts/auditor.md` rendered
  with the bounded package and the scoped repository files, read from the
  materialization, never the checkout. Records live under
  `.kogen/runtime/shaping-audits/<slug>/auditor/`. Records are append-only so
  a later audit of the same revision or a changed checkout never replaces
  earlier evidence.
  """

  alias Kogen.ShapingAudit.{Finding, Materialization, Report}

  @prompt_path "priv/kogen/prompts/auditor.md"
  @answer_sentence "Report as `answer-not-applied` any entry under `## Shaper answers` whose decision is not reflected in INTENT.md, scenarios.yaml or `## Assumed`."
  @budget_bytes 160_000
  @max_findings 50
  @max_summary 200
  @max_detail 1000
  @max_paths 10
  @contract_version "exact-config-reserved-v2"

  @doc false
  def contract_version, do: @contract_version

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
    case ledger(ctx) do
      {:ok, records} -> decide(ctx, records, opts)
      {:error, reason} -> integrity_failure(reason)
    end
  end

  @doc false
  def confirmation_admission(ctx) do
    case ledger(ctx) do
      {:ok, records} ->
        budget = records |> binding_records(ctx) |> budget_state()

        if confirmation_before_bound?(budget, confirm?: true),
          do: {:error, :confirmation_before_bound},
          else: :ok

      # The layer retains its explicit integrity diagnostic. Its ledger
      # failure also invalidates every positive report before cache reuse.
      {:error, _reason} ->
        :ok
    end
  end

  defp decide(ctx, all_records, opts) do
    records = binding_records(all_records, ctx)
    normal_records = Enum.reject(records, &(&1["confirmation_grant"] == true))
    latest = List.last(records)
    budget = budget_state(records)

    cond do
      confirmation_before_bound?(budget, opts) ->
        missing_confirmation(
          ctx,
          latest,
          budget,
          "explicit confirmation requires the exhausted normal auditor budget",
          "unavailable"
        )

      confirmation_available?(budget, opts) ->
        launch_new_revision(
          ctx,
          next_seq(records),
          Keyword.put(opts, :confirmation_grant?, true),
          latest
        )

      reusable_latest?(latest, ctx) ->
        to_run_result(latest, true, bound_reached?(budget))
        |> Map.put("budget_state", budget)

      budget["normal_exhausted"] ->
        missing_confirmation(ctx, latest, budget, "the normal auditor budget is exhausted")

      Keyword.get(opts, :launch?, false) ->
        launch_new_revision(ctx, next_seq(records), opts, List.last(normal_records))

      true ->
        reason =
          if latest,
            do: "the current revision needs a fresh auditor run, and launch is disabled",
            else: "no prior auditor run to reuse, and launch is disabled"

        missing_confirmation(ctx, latest || latest_diagnostic(ctx), budget, reason, "not-run")
    end
  end

  defp binding_records(records, ctx) do
    records
    |> Enum.filter(
      &(&1["route"] == ctx.route and &1["head"] == ctx.head and &1["counted"] != false)
    )
    |> Enum.sort_by(& &1["seq"])
  end

  defp next_seq(records), do: Enum.max([0 | Enum.map(records, & &1["seq"])]) + 1

  defp budget_state(records) do
    normal = Enum.reject(records, &(&1["confirmation_grant"] == true))
    grant_used? = Enum.any?(records, &(&1["confirmation_grant"] == true))

    %{
      "normal_limit" => 2,
      "normal_count" => length(normal),
      "normal_exhausted" => normal_budget_exhausted?(normal),
      "confirmation_grant" => if(grant_used?, do: "used", else: "available")
    }
  end

  defp confirmation_available?(budget, opts),
    do:
      budget["normal_exhausted"] and Keyword.get(opts, :confirm?, false) and
        budget["confirmation_grant"] == "available"

  defp confirmation_before_bound?(budget, opts),
    do: Keyword.get(opts, :confirm?, false) and not budget["normal_exhausted"]

  defp bound_reached?(budget),
    do: budget["normal_exhausted"] or budget["confirmation_grant"] == "used"

  defp reusable_latest?(nil, _ctx), do: false
  defp reusable_latest?(latest, ctx), do: same_binding?(latest, ctx) and reusable_record?(latest)

  defp launch_new_revision(ctx, seq, opts, prior) do
    result = launch_and_record(ctx, seq, opts)
    prior = prior || latest_diagnostic(ctx)

    if prior && not same_binding?(prior, ctx) do
      Map.put(result, "previous_audit", diagnostic_record(prior))
    else
      result
    end
  end

  defp normal_budget_exhausted?(normal_records) do
    length(normal_records) >= 2 or
      match?(
        %{"status" => status} when status in ["unavailable", "rejected"],
        List.last(normal_records)
      )
  end

  defp same_binding?(record, ctx) do
    record["revision"] == ctx.revision and record["head"] == ctx.head and
      record["route"] == ctx.route and
      record["config_fingerprint"] == config_fingerprint(ctx)
  end

  defp reusable_record?(%{"status" => "ok"} = record),
    do: record["contract_version"] == @contract_version and record["phase"] == "completed"

  defp reusable_record?(_record), do: true

  @doc false
  def confirmed?(ctx, layer) when is_map(layer) do
    with @contract_version <- layer["contract_version"],
         {:ok, records} <- ledger(ctx),
         latest when is_map(latest) <-
           records
           |> binding_records(ctx)
           |> List.last() do
      same_binding?(latest, ctx) and latest["status"] == "ok" and layer["status"] == "ok" and
        reusable_record?(latest) and latest["attempt_id"] == layer["attempt_id"] and
        layer["audited_binding"] == ctx_binding(ctx)
    else
      _ -> false
    end
  end

  def confirmed?(_ctx, _layer), do: false

  defp missing_confirmation(ctx, prior, budget, reason, status \\ "missing-confirmation") do
    Map.merge(base_result(status, reason), %{
      "bound_reached" => budget["normal_exhausted"] or budget["confirmation_grant"] == "used",
      "budget_state" => budget,
      "previous_audit" => diagnostic_record(prior),
      "requested_binding" => ctx_binding(ctx)
    })
  end

  defp diagnostic_record(nil), do: nil

  defp diagnostic_record(record) do
    Map.take(record, [
      "revision",
      "head",
      "route",
      "status",
      "reason",
      "seq",
      "counted",
      "confirmation_grant",
      "findings",
      "session_id",
      "recorded_at"
    ])
  end

  defp ctx_binding(ctx) do
    binding = %{"revision" => ctx.revision, "head" => ctx.head, "route" => ctx.route}

    case config_fingerprint(ctx) do
      nil -> binding
      fingerprint -> Map.put(binding, "config_fingerprint", fingerprint)
    end
  end

  defp config_fingerprint(%{config_fingerprint: fingerprint}) when is_binary(fingerprint),
    do: fingerprint

  defp config_fingerprint(%{config: config}) when is_map(config),
    do: Kogen.Intent.config_fingerprint(config)

  defp config_fingerprint(_ctx), do: nil

  defp to_run_result(record, reused?, bound_reached?) do
    Map.merge(base_result(record["status"], record["reason"]), %{
      "findings" => record["findings"] || [],
      "elapsed_ms" => if(record["phase"] == "reserved", do: nil, else: record["elapsed_ms"] || 0),
      "effects" => record["effects"],
      "not_audited" => record["not_audited"] || [],
      "session_id" => record["session_id"],
      "launched" => record["launched"] == true,
      "dropped" => record["dropped"] || %{"findings" => 0, "fields" => 0, "paths" => 0},
      "reused" => reused?,
      "attempt_id" => record["attempt_id"],
      "contract_version" => record["contract_version"],
      "bound_reached" => bound_reached?,
      "audited_binding" =>
        ctx_binding(%{
          revision: record["revision"],
          head: record["head"],
          route: record["route"],
          config_fingerprint: record["config_fingerprint"]
        })
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

  defp launch_and_record(ctx, seq, opts) do
    reservation = %{
      "schema_version" => 2,
      "contract_version" => @contract_version,
      "attempt_id" => new_attempt_id(),
      "phase" => "reserved",
      "route" => ctx.route,
      "config_fingerprint" => config_fingerprint(ctx),
      "revision" => ctx.revision,
      "head" => ctx.head,
      "seq" => seq,
      "counted" => true,
      "confirmation_grant" => Keyword.get(opts, :confirmation_grant?, false),
      "recorded_at" => recorded_at(),
      "status" => "unavailable",
      "reason" => "auditor attempt interrupted or completion missing; allowance remains consumed",
      "findings" => [],
      "launched" => false,
      "effects" => "unknown"
    }

    case reserve(ctx, reservation) do
      {:ok, path} -> finish_attempt(ctx, path, reservation, opts)
      {:error, reason} -> integrity_failure(reason)
    end
  end

  defp finish_attempt(ctx, path, reservation, opts) do
    outcome =
      case Kogen.Intent.auditor_config(ctx.config || %{route: ctx.route}) do
        {:ok, auditor} ->
          execute(ctx, auditor, reservation, opts)

        {:error, reason} ->
          Map.merge(reservation, %{"reason" => reason, "effects" => "not-launched"})
      end

    record = outcome |> Map.put("phase", "completed")

    with :ok <- complete(path, reservation, record),
         {:ok, all_records} <- ledger(ctx) do
      budget = all_records |> binding_records(ctx) |> budget_state()
      to_run_result(record, false, bound_reached?(budget)) |> Map.put("budget_state", budget)
    else
      {:error, reason} -> integrity_failure(reason)
    end
  end

  defp execute(ctx, auditor, reservation, opts) do
    {prompt, not_audited} = render_prompt(ctx, Keyword.get(opts, :prior_failures, []))
    before_manifest = default_manifest(ctx)
    started_at = System.monotonic_time(:millisecond)
    outcome = default_launcher(ctx, auditor, prompt)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    after_manifest = default_manifest(ctx)

    base =
      Map.merge(reservation, %{
        "harness" => auditor.harness,
        "model" => auditor.model,
        "effort" => auditor.effort,
        "prompt_sha256" => sha256_hex(prompt),
        "elapsed_ms" => elapsed_ms,
        "not_audited" => not_audited,
        "session_id" => nil,
        "reason" => nil,
        "dropped" => %{"findings" => 0, "fields" => 0, "paths" => 0},
        "effects" => "watched-paths-inspected"
      })

    finish_outcome(base, outcome, manifest_diff(before_manifest, after_manifest))
  end

  defp finish_outcome(base, {:ok, %{session_id: session_id, message: message}}, []) do
    base = Map.merge(base, %{"session_id" => session_id, "launched" => true})

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

  defp finish_outcome(base, {:error, reason}, []) do
    Map.merge(base, %{
      "status" => "unavailable",
      "reason" => "auditor launch failed: #{inspect(reason)}"
    })
  end

  defp finish_outcome(base, outcome, paths) do
    Map.merge(base, %{
      "status" => "rejected",
      "launched" => match?({:ok, _}, outcome),
      "reason" => "the auditor wrote to: #{Enum.join(paths, ", ")}"
    })
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

  @doc "The legacy diagnostic path, or a globally unique counted attempt path."
  def record_path(root, slug, revision, route, head \\ nil, seq \\ nil) do
    hash = route |> sha256_hex() |> String.slice(0, 12)

    suffix =
      if is_binary(head), do: "-#{head}-#{seq || "uncounted"}-#{new_attempt_id()}", else: ""

    Path.join([Report.runtime_dir(root, slug), "auditor", "#{revision}-#{hash}#{suffix}.json"])
  end

  defp new_attempt_id, do: Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

  @doc "Stored records, or an explicit integrity error; malformed evidence never restores allowance."
  def load_records(ctx) do
    with {:ok, records} <- ledger(ctx) do
      Enum.filter(records, &(&1["route"] == ctx.route and &1["head"] == ctx.head))
    end
  end

  defp ledger(ctx) do
    dir = Path.join(Report.runtime_dir(ctx.root, ctx.slug), "auditor")

    case File.ls(dir) do
      {:ok, names} ->
        with :ok <- valid_entries(names),
             {:ok, records} <-
               read_records(dir, Enum.filter(names, &String.ends_with?(&1, ".json"))),
             :ok <- unique_records(records) do
          {:ok, records}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot read auditor ledger: #{inspect(reason)}"}
    end
  end

  defp valid_entries(names) do
    invalid =
      Enum.find(names, fn name ->
        not String.ends_with?(name, ".json") and
          not (String.ends_with?(name, ".completion") and
                 String.replace_suffix(name, ".completion", "") in names)
      end)

    if invalid, do: {:error, "unexpected auditor ledger entry: #{invalid}"}, else: :ok
  end

  defp read_records(dir, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, records} ->
      case read_record(dir, name) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unique_records(records) do
    counted = Enum.filter(records, &(&1["counted"] != false))
    bindings = Enum.map(counted, &{&1["head"], &1["route"], &1["seq"]})
    ids = records |> Enum.map(& &1["attempt_id"]) |> Enum.reject(&is_nil/1)

    grants =
      counted
      |> Enum.filter(&(&1["confirmation_grant"] == true))
      |> Enum.map(&{&1["head"], &1["route"]})

    if complete_sequences?(counted) and length(Enum.uniq(bindings)) == length(bindings) and
         length(Enum.uniq(ids)) == length(ids) and
         length(Enum.uniq(grants)) == length(grants),
       do: :ok,
       else:
         {:error,
          "incomplete or duplicate auditor ledger attempt, sequence or confirmation grant"}
  end

  defp complete_sequences?(records) do
    records
    |> Enum.group_by(&{&1["head"], &1["route"]})
    |> Enum.all?(fn {_binding, attempts} ->
      Enum.sort(Enum.map(attempts, & &1["seq"])) == Enum.to_list(1..length(attempts))
    end)
  end

  defp latest_diagnostic(ctx) do
    case ledger(ctx) do
      {:ok, records} ->
        records
        |> Enum.reject(&same_binding?(&1, ctx))
        |> Enum.max_by(&(&1["recorded_at"] || ""), fn -> nil end)

      {:error, _} ->
        nil
    end
  end

  defp recorded_at, do: DateTime.to_iso8601(DateTime.utc_now())

  defp read_json(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, text} <- File.read(path),
         {:ok, record} when is_map(record) <- Jason.decode(text) do
      {:ok, record}
    else
      _ -> {:error, "invalid auditor ledger record: #{Path.basename(path)}"}
    end
  end

  defp read_record(dir, name) do
    path = Path.join(dir, name)

    with {:ok, record} <- read_json(path),
         true <- valid_record?(record) do
      read_completion(path, record)
    else
      {:error, _} = error -> error
      _ -> {:error, "invalid auditor ledger fields: #{name}"}
    end
  end

  defp valid_record?(record) do
    valid_binding?(record) and valid_result?(record) and valid_count?(record) and
      valid_version?(record)
  end

  defp valid_binding?(record) do
    Enum.all?(~w(revision head route recorded_at), &(is_binary(record[&1]) and record[&1] != ""))
  end

  defp valid_result?(record) do
    record["status"] in ["ok", "unavailable", "rejected"] and is_list(record["findings"]) and
      Enum.all?(record["findings"], &valid_finding?/1)
  end

  defp valid_finding?(finding) when is_map(finding) do
    Enum.all?(~w(id rule layer message), &is_binary(finding[&1])) and
      finding["severity"] in ["blocking", "advisory"] and is_list(finding["paths"])
  end

  defp valid_finding?(_finding), do: false

  defp valid_count?(record) do
    record["counted"] in [nil, true, false] and record["confirmation_grant"] in [nil, true, false] and
      (record["counted"] == false or (is_integer(record["seq"]) and record["seq"] > 0)) and
      not (record["counted"] == false and record["confirmation_grant"] == true)
  end

  defp valid_version?(%{"schema_version" => 1}), do: true

  defp valid_version?(%{"schema_version" => 2} = record) do
    record["contract_version"] in ["exact-latest-reserved-v1", @contract_version] and
      valid_identity?(record["attempt_id"]) and
      record["counted"] == true and is_boolean(record["confirmation_grant"]) and
      valid_phase?(record)
  end

  defp valid_version?(_record), do: false

  defp valid_identity?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{48}\z/, id)

  defp valid_phase?(%{"phase" => "completed"}), do: true

  defp valid_phase?(%{"phase" => "reserved"} = record),
    do:
      record["status"] == "unavailable" and record["findings"] == [] and
        record["effects"] == "unknown" and record["launched"] == false

  defp valid_phase?(_record), do: false

  defp read_completion(path, %{"schema_version" => 1} = record) do
    case File.lstat(path <> ".completion") do
      {:error, :enoent} -> {:ok, record}
      _present_or_unreadable -> {:error, "legacy attempt has unexpected completion"}
    end
  end

  defp read_completion(path, reservation) do
    case File.lstat(path <> ".completion") do
      {:error, :enoent} ->
        if reservation["phase"] == "reserved" and reservation["status"] == "unavailable",
          do: {:ok, reservation},
          else: {:error, "missing auditor reservation"}

      _ ->
        with "reserved" <- reservation["phase"],
             {:ok, completion} <- read_json(path <> ".completion"),
             true <- valid_record?(completion),
             "completed" <- completion["phase"],
             true <- same_attempt?(reservation, completion) do
          {:ok, completion}
        else
          _ -> {:error, "invalid auditor completion: #{Path.basename(path)}"}
        end
    end
  end

  defp same_attempt?(a, b),
    do:
      Map.take(
        a,
        ~w(schema_version contract_version attempt_id revision head route config_fingerprint seq counted confirmation_grant recorded_at)
      ) ==
        Map.take(
          b,
          ~w(schema_version contract_version attempt_id revision head route config_fingerprint seq counted confirmation_grant recorded_at)
        )

  defp reserve(ctx, reservation) do
    dir = Path.join(Report.runtime_dir(ctx.root, ctx.slug), "auditor")
    File.mkdir_p!(dir)
    path = Path.join(dir, reservation["attempt_id"] <> ".json")

    case exclusive_write(path, reservation) do
      :ok -> {:ok, path}
      {:error, _} = error -> error
    end
  end

  defp complete(path, reservation, record) do
    case read_json(path) do
      {:ok, ^reservation} -> exclusive_write(path <> ".completion", record)
      _ -> {:error, "auditor reservation changed before completion"}
    end
  end

  defp exclusive_write(path, record) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, Jason.encode!(record, pretty: true) <> "\n"),
               :ok <- :file.sync(io) do
            :ok
          else
            error -> {:error, "cannot persist auditor attempt: #{inspect(error)}"}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "cannot exclusively persist auditor attempt: #{inspect(reason)}"}
    end
  end

  defp integrity_failure(reason) do
    base_result("unavailable", "auditor ledger integrity: #{reason}")
    |> Map.put("bound_reached", true)
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
      |> String.replace(
        "At the budget, report what you have.",
        @answer_sentence <> "\n\nAt the budget, report what you have.",
        global: false
      )

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
