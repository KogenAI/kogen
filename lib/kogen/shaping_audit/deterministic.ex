defmodule Kogen.ShapingAudit.Deterministic do
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  @moduledoc """
  Deterministic slice-1 Shaping audit rules.

  All package and repository checks read the private materialization. The one
  exception is `prior_failures/3`, which reads retained checkout records with a
  bounded stat-before-read policy.
  """

  alias Kogen.Build.VerificationPlan
  alias Kogen.Harness.Claude
  alias Kogen.ShapingAudit.{Finding, HeadlessInput}
  alias Kogen.VerificationPolicy

  @ledger_path "priv/kogen/test-reliability.yaml"
  @remediation_path "priv/kogen/test-reliability-remediation.yaml"
  @max_records 200
  @max_record_bytes 32 * 1024 * 1024

  @spec run(map()) :: %{String.t() => term()}
  def run(ctx) do
    case package_findings(ctx) do
      {:ok, findings} ->
        %{"status" => "ok", "findings" => findings}

      {:unavailable, reason, findings} ->
        %{"status" => "unavailable", "reason" => reason, "findings" => findings}
    end
  end

  defp package_findings(%{intent: intent, scenarios: scenarios})
       when not is_map(intent) or not is_list(scenarios),
       do: {:ok, [package_invalid()]}

  defp package_findings(ctx) do
    guards = List.wrap(ctx.intent["may_change_guarded_paths"])
    added = get_in(ctx.intent, ["catalog_changes", "add"]) |> List.wrap()

    common =
      title_findings(ctx.intent) ++
        ledger_findings(ctx, guards) ++
        stale_anchor_findings(ctx) ++ prior_failure_findings(ctx) ++ input_findings(ctx)

    case VerificationPlan.load(ctx.materialization) do
      {:ok, catalog} ->
        findings =
          common ++
            proof_findings(ctx, guards, catalog, added) ++
            controller_read_findings(ctx, catalog) ++
            live_owner_findings(ctx, catalog) ++
            paid_unproven_findings(ctx, catalog) ++
            paid_overbroad_findings(ctx, catalog)

        {:ok, findings}

      {:error, reason} ->
        finding =
          Finding.new("repository-invalid", nil, %{
            "scope" => "environment",
            "disputable" => false,
            "paths" => [],
            "message" => reason
          })

        {:unavailable, reason, common ++ [finding]}
    end
  end

  defp package_invalid do
    Finding.new("package-invalid", nil, %{
      "message" => "the package's intent.yaml or scenarios.yaml is missing or unparseable"
    })
  end

  defp proof_findings(ctx, guards, catalog, added) do
    ctx.scenarios
    |> VerificationPlan.proof_errors(guards, catalog, ctx.materialization, added: added)
    |> Enum.map(fn {kind, detail} ->
      Finding.new(kind, detail, %{
        "disputable" => false,
        "paths" => proof_error_paths(kind, detail),
        "message" => "#{kind}: #{detail}"
      })
    end)
  end

  defp proof_error_paths(kind, detail)
       when kind in ["unguarded-affected-path", "proof-selector-missing", "unsupported-selector"],
       do: [detail]

  defp proof_error_paths(_kind, _detail), do: []

  defp controller_paths do
    [claude_settings_relative() | VerificationPolicy.controller_paths()]
    |> Enum.reject(&is_nil/1)
  end

  defp claude_settings_relative do
    Claude.settings_path()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "priv"))
    |> case do
      [] -> nil
      segments -> Path.join(segments)
    end
  rescue
    _ -> nil
  end

  defp controller_read_findings(ctx, _catalog) do
    watched = controller_paths()

    for path <- affected_paths(ctx.scenarios), path in watched do
      Finding.new("controller-read-path", path, %{
        "disputable" => false,
        "paths" => [path],
        "message" => "#{path} is read by the Build controller's own verification guard"
      })
    end
    |> Enum.uniq_by(& &1["id"])
  end

  defp live_owner_findings(ctx, catalog) do
    selected = selected_targets(ctx.scenarios)
    affected = affected_paths(ctx.scenarios)

    for {name, entry} <- catalog.targets,
        entry["provider_backed"] == true,
        owner = entry["owner"],
        is_binary(owner),
        owner in affected,
        name not in selected do
      Finding.new("edited-live-owner-unselected", name, %{
        "disputable" => false,
        "paths" => [owner],
        "message" => "#{owner} (#{name}'s owner) is edited but #{name} is not selected"
      })
    end
  end

  defp paid_unproven_findings(ctx, catalog) do
    affected = affected_paths(ctx.scenarios)

    for {name, entry} <- catalog.targets,
        entry["provider_backed"] == true,
        name in selected_targets(ctx.scenarios),
        paid_affected?(entry, affected),
        not paid_path_proven?(ctx.files, name) do
      paths = paid_affected_paths(entry, affected)

      Finding.new("paid-path-unproven", name, %{
        "disputable" => true,
        "paths" => paths,
        "message" =>
          "#{name}'s paid path is unproven: add evidence/probe-<topic>/RESULT.md naming #{name}, or a proving-run record"
      })
    end
  end

  defp paid_affected?(entry, affected), do: paid_affected_paths(entry, affected) != []

  defp paid_affected_paths(entry, affected) do
    owner = entry["owner"]
    prepare = List.wrap(entry["prepare"])

    Enum.filter(affected, fn path ->
      path == owner or Enum.any?(prepare, &(&1 == path))
    end)
  end

  defp paid_path_proven?(files, target) do
    Enum.any?(files, fn {path, bytes} ->
      regular_probe?(path) and contains_target?(bytes, target)
    end) or
      Enum.any?(files, fn {path, bytes} ->
        proving_run_file?(path) and contains_target?(bytes, target)
      end)
  end

  defp regular_probe?(path), do: Regex.match?(~r/^evidence\/probe-[^\/]+\/RESULT\.md$/, path)

  defp proving_run_file?(path),
    do: Regex.match?(~r/^evidence\/proving-run-[^\/]+\/.+$/, path)

  defp contains_target?(bytes, target), do: String.contains?(to_string(bytes), target)

  defp paid_overbroad_findings(ctx, catalog) do
    for scenario <- ctx.scenarios,
        target = get_in(scenario, ["proof", "paid_target"]),
        is_binary(target),
        target != "none",
        Map.has_key?(catalog.targets, target),
        not selected_elsewhere?(ctx.scenarios, scenario, target),
        affected = List.wrap(get_in(scenario, ["proof", "affected_paths"])),
        affected != [],
        Enum.all?(affected, &String.starts_with?(&1, "test/support/")) do
      Finding.new("paid-target-overbroad", scenario["id"], %{
        "paths" => affected,
        "scenario" => scenario["id"],
        "message" =>
          "#{scenario["id"]} selects #{target} for test/support/ mechanics only; introduce the cheaper check (offline test, then an offline replay of retained real provider evidence, then a minimal live smoke)"
      })
    end
  end

  defp selected_elsewhere?(scenarios, scenario, target) do
    Enum.any?(scenarios, fn other ->
      other["id"] != scenario["id"] and target in List.wrap(other["verified_by"])
    end)
  end

  defp selected_targets(scenarios),
    do: scenarios |> Enum.flat_map(&List.wrap(&1["verified_by"])) |> Enum.uniq()

  defp affected_paths(scenarios),
    do:
      scenarios
      |> Enum.flat_map(&List.wrap(get_in(&1, ["proof", "affected_paths"])))
      |> Enum.uniq()

  # -- test-reliability ledger ----------------------------------------------

  defp ledger_findings(ctx, guards) do
    with {:ok, bytes} <- File.read(Path.join(ctx.materialization, @ledger_path)),
         {:ok, ledger} <- decode_ledger(bytes) do
      declarations = List.wrap(ledger["declarations"])
      catalogued = Enum.filter(declarations, &is_map/1)

      touched =
        catalogued
        |> Enum.map(& &1["file"])
        |> Enum.filter(&(&1 in affected_paths(ctx.scenarios)))
        |> Enum.uniq()

      cond do
        touched != [] and not guarded?(@ledger_path, guards) ->
          [
            Finding.new("ledger-closure", nil, %{
              "severity" => "advisory",
              "disputable" => false,
              "paths" => touched ++ [@ledger_path],
              "message" =>
                "#{Enum.join(touched, ", ")} holds catalogued tests; renaming one edits its row's declaration by hand in #{@ledger_path}; editing a body or adding a test needs no row change; guarding the file is harmless"
            })
          ]

        row_change?(ctx.scenarios, catalogued) and
            (not guarded?(@ledger_path, guards) or not guarded?(@remediation_path, guards)) ->
          missing =
            [@ledger_path, @remediation_path]
            |> Enum.reject(&guarded?(&1, guards))

          [
            Finding.new("ledger-row-update-unstated", nil, %{
              "severity" => "advisory",
              "disputable" => false,
              "paths" => missing,
              "message" =>
                "a catalogued test row is added or deleted; guard and update both #{@ledger_path} and #{@remediation_path} (renames edit the declaration in #{@ledger_path} only)"
            })
          ]

        true ->
          []
      end
    else
      _ -> []
    end
  end

  defp decode_ledger(bytes) do
    case Jason.decode(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> YamlElixir.read_from_string(bytes)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp row_change?(scenarios, declarations) do
    declarations =
      Enum.filter(declarations, &(is_binary(&1["declaration"]) and is_binary(&1["file"])))

    Enum.any?(scenarios, fn scenario ->
      scenario_texts(scenario)
      |> Enum.flat_map(&split_sentences/1)
      |> Enum.any?(fn sentence ->
        deletion =
          whole_word?(
            sentence,
            ~w(delete deletes deleted deleting remove removes removed removing)
          )

        addition = whole_word?(sentence, ~w(add adds added adding))
        mentions_row = phrase?(sentence, "ledger row") or phrase?(sentence, "catalog row")

        declaration_delete =
          Enum.any?(declarations, fn declaration ->
            String.contains?(sentence, declaration["declaration"]) and
              declaration["file"] in affected_paths_from_scenario(scenario) and deletion
          end)

        declaration_delete or (mentions_row and addition)
      end)
    end)
  end

  defp scenario_texts(scenario) do
    ["given", "when", "then", "wrong_result", "evidence", "tests"]
    |> Enum.flat_map(fn key ->
      case scenario[key] do
        value when is_list(value) -> Enum.map(value, &to_string/1)
        nil -> []
        value -> [to_string(value)]
      end
    end)
  end

  defp split_sentences(text), do: Regex.split(~r/[.;\n]/, text, trim: true)

  defp whole_word?(text, words),
    do: Enum.any?(words, &Regex.match?(~r/(?i)\b#{Regex.escape(&1)}\b/u, text))

  defp phrase?(text, phrase), do: Regex.match?(~r/(?i)#{Regex.escape(phrase)}/u, text)

  defp affected_paths_from_scenario(scenario),
    do: List.wrap(get_in(scenario, ["proof", "affected_paths"]))

  defp guarded?(path, guards), do: Enum.any?(guards, &VerificationPlan.path_matches?(path, &1))

  # -- stale anchors ---------------------------------------------------------

  defp stale_anchor_findings(ctx) do
    baseline = get_in(ctx.intent, ["shaped_against", "head"])

    cond do
      baseline == nil or baseline == "" ->
        []

      not is_binary(baseline) or String.match?(baseline, ~r/^0+$/) or
          not resolvable?(ctx.materialization, baseline) ->
        [
          Finding.new("stale-anchor-baseline-unavailable", nil, %{
            "message" =>
              "shaped_against #{baseline} is not a local commit: re-verify citations and update shaped_against"
          })
        ]

      true ->
        text = package_text(ctx.files)
        path_line_findings(ctx, baseline, text) ++ identifier_findings(ctx, baseline, text)
    end
  end

  defp resolvable?(root, ref) do
    case System.cmd("git", ["cat-file", "-e", ref <> "^{commit}"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp package_text(files), do: files |> Map.values() |> Enum.map_join("\n", &safe_text/1)
  defp safe_text(bytes), do: if(String.valid?(bytes), do: bytes, else: "")

  defp path_line_findings(ctx, baseline, text) do
    ~r/(?<![A-Za-z0-9_])([A-Za-z0-9_.\/-]+):(\d+)\b/
    |> Regex.scan(text)
    |> Enum.uniq()
    |> Enum.flat_map(fn [_, path, line] ->
      path_line_finding(ctx, baseline, path, String.to_integer(line))
    end)
  end

  defp path_line_finding(ctx, baseline, path, line) do
    case Kogen.Git.blob(baseline, path, ctx.materialization) do
      {:ok, base_bytes} ->
        base_line = Enum.at(String.split(base_bytes, "\n"), line - 1)

        stale? =
          case head_blob(ctx.materialization, path) do
            {:ok, head_bytes} ->
              base_line != nil and base_line != Enum.at(String.split(head_bytes, "\n"), line - 1)

            :absent ->
              base_line != nil
          end

        if stale? do
          [
            Finding.new("stale-anchor", "#{path}:#{line}", %{
              "paths" => [path],
              "message" => "#{path}:#{line} differs between shaped_against and HEAD"
            })
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp head_blob(materialization, path) do
    case File.read(Path.join(materialization, path)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> :absent
    end
  end

  defp identifier_findings(ctx, baseline, text) do
    ~r/`([A-Za-z_][A-Za-z0-9_]*)`/
    |> Regex.scan(text)
    |> Enum.uniq()
    |> Enum.flat_map(fn [_, identifier] -> identifier_finding(ctx, baseline, identifier) end)
  end

  defp identifier_finding(ctx, baseline, identifier) do
    if grep?(ctx.materialization, baseline, identifier) and
         not grep?(ctx.materialization, "HEAD", identifier) do
      [
        Finding.new("stale-anchor", identifier, %{
          "message" => "`#{identifier}` existed at shaped_against and is gone at HEAD"
        })
      ]
    else
      []
    end
  end

  defp grep?(root, rev, needle) do
    case System.cmd("git", ["grep", "-F", "-q", needle, rev], cd: root, stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  # -- prior failures --------------------------------------------------------

  defp prior_failure_findings(ctx) do
    records =
      prior_failures(ctx.root, ctx.intent["id"], Keyword.get(ctx.opts || [], :read, &File.read/1))

    if records == [] do
      []
    else
      summary = Enum.map_join(records, "; ", &"#{&1["build_id"]} (#{&1["signature"]})")

      [
        Finding.new("prior-failures", nil, %{
          "severity" => "advisory",
          "message" => "prior failed Builds for this Draft: #{summary}"
        })
      ]
    end
  end

  @spec prior_failures(Path.t(), String.t(), (Path.t() -> {:ok, binary()} | {:error, term()})) ::
          [map()]
  def prior_failures(root, intent_id, read \\ &File.read/1) do
    Path.join(root, ".kogen/runtime/scenario-tracking/*/record.json")
    |> Path.wildcard()
    |> Enum.map(&{&1, mtime(&1)})
    |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
    |> Enum.take(@max_records)
    |> Enum.flat_map(fn {path, _} -> record_matching(path, intent_id, read) end)
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp record_matching(path, intent_id, read) do
    with {:ok, %File.Stat{size: size}} when size <= @max_record_bytes <- File.stat(path),
         {:ok, bytes} <- read.(path),
         {:ok, record} <- Jason.decode(bytes),
         true <- record["status"] == "failed",
         ^intent_id <- get_in(record, ["intent", "id"]),
         signature when is_binary(signature) <- last_failure(record) do
      [
        %{
          "build_id" => Path.basename(Path.dirname(path)),
          "signature" => String.slice(signature, 0, 200)
        }
      ]
    else
      _ -> []
    end
  end

  defp last_failure(%{"attempts" => attempts}) when is_list(attempts) do
    attempts
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"status" => "failed", "failure" => failure} when is_binary(failure) -> failure
      _ -> nil
    end)
  end

  defp last_failure(_), do: nil

  # -- recorded inputs ---------------------------------------------------------

  # Only packages carrying `evidence/inputs/NNNN.md` copies are checked. The
  # brief lives at `evidence/brief.md` and is outside both rules.
  defp input_findings(ctx) do
    inputs =
      for {path, bytes} <- ctx.files,
          [_, number] <- [Regex.run(~r/^evidence\/inputs\/(\d+)\.md$/, path)] do
        digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        {number, "in-#{number}-#{String.slice(digest, 0, 8)}"}
      end
      |> Enum.sort()

    if inputs == [] do
      []
    else
      questions_text = Map.get(ctx.files, "questions.md")

      accepted =
        for {number, id} <- inputs,
            path = "evidence/inputs/#{number}.md",
            bytes when is_binary(bytes) <- [Map.get(ctx.files, path)],
            do: %{"id" => id, "text" => bytes}

      exact = HeadlessInput.recorded(questions_text, accepted)
      per_entry = HeadlessInput.token_counts(questions_text)

      not_recorded =
        for {_number, id} <- inputs, Map.get(exact, id, 0) != 1 do
          Finding.new("input-not-recorded", id, %{
            "paths" => ["questions.md"],
            "message" =>
              "accepted input [input #{id}] is not recorded exactly once: add the reversible kogen-recorded-input-v1 frame with its exact bytes under ## Shaper answers"
          })
        end

      twice =
        per_entry
        |> Enum.filter(fn {_id, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
        |> Enum.map(fn id ->
          Finding.new("input-recorded-twice", id, %{
            "paths" => ["questions.md"],
            "message" =>
              "input #{id} is recorded by more than one ## Shaper answers entry: keep exactly one"
          })
        end)

      not_recorded ++ twice
    end
  end

  # -- title / commit-subject format ----------------------------------------

  defp title_findings(intent) do
    field_finding("title-format", "title", intent["title"], 50, false) ++
      field_finding("commit-subject-format", "commit_subject", intent["commit_subject"], 72, true)
  end

  # credo:disable-for-next-line Credo.Refactor.CyclomaticComplexity
  defp field_finding(rule, field, value, limit, required?) do
    cond do
      required? and blank?(value) ->
        [Finding.new(rule, nil, %{"message" => "commit_subject is missing"})]

      blank?(value) ->
        []

      not is_binary(value) ->
        [Finding.new(rule, nil, %{"message" => "#{field} must be a string"})]

      true ->
        reasons =
          [
            if(String.length(value) > limit,
              do: "more than #{limit} characters (#{String.length(value)})"
            ),
            if(String.ends_with?(value, "."), do: "ends with a trailing period"),
            if(lowercase_start?(value), do: "starts with a lowercase letter"),
            if(
              field == "commit_subject" and
                String.contains?(String.trim_trailing(value, "\n"), "\n"),
              do: "more than one line"
            )
          ]
          |> Enum.reject(&is_nil/1)

        if reasons == [],
          do: [],
          else: [Finding.new(rule, nil, %{"message" => "#{field} #{Enum.join(reasons, "; ")}"})]
    end
  end

  defp blank?(value), do: value == nil or (is_binary(value) and String.trim(value) == "")

  defp lowercase_start?(value) do
    case String.next_grapheme(value) do
      {grapheme, _} ->
        grapheme == String.downcase(grapheme) and grapheme != String.upcase(grapheme)

      nil ->
        false
    end
  end
end
