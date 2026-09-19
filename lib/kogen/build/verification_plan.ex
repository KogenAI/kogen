defmodule Kogen.Build.VerificationPlan do
  @moduledoc """
  Loads and freezes the repository verification-target catalog and turns the
  scenario proof declarations into one deterministic execution/readiness plan.
  """

  @catalog_path "priv/kogen/verification_targets.yaml"
  @aggregate_names ~w(live live-all)

  def load(root \\ File.cwd!()) do
    path = Path.join(root, @catalog_path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(bytes),
         entries when is_list(entries) <- decoded["targets"] || decoded,
         entries <- Enum.map(entries, &normalize_entry/1),
         :ok <- validate_catalog(entries),
         :ok <- validate_declared_targets(entries, root),
         {:ok, ordered} <- order(entries) do
      targets = Map.new(entries, &{&1["name"], &1})

      {:ok,
       %{
         path: path,
         bytes: bytes,
         sha256: sha256(bytes),
         entries: entries,
         targets: targets,
         ordered_targets: Enum.map(ordered, & &1["name"])
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "could not load verification target catalog: #{inspect(reason)}"}

      _ ->
        {:error, "verification target catalog is malformed"}
    end
  end

  def build(scenarios, guards, catalog, root \\ File.cwd!())
      when is_list(scenarios) and is_list(guards) and is_map(catalog) do
    with :ok <- validate_proofs(scenarios, guards, catalog, root),
         selected <-
           scenarios
           |> Enum.map(&get_in(&1, ["proof", "paid_target"]))
           |> Enum.reject(&(&1 == "none"))
           |> Enum.uniq(),
         {:ok, ordered} <- selected_order(selected, catalog) do
      offline = scenarios |> Enum.flat_map(&get_in(&1, ["proof", "offline"])) |> Enum.uniq()

      affected =
        scenarios |> Enum.flat_map(&get_in(&1, ["proof", "affected_paths"])) |> Enum.uniq()

      offline_commands = Enum.map(offline, &selector_command(&1, catalog))

      rehearsals =
        ordered
        |> Enum.map(&get_in(catalog, [:targets, &1, "rehearsal", "command"]))
        |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         targets: ["check" | ordered],
         offline: offline,
         offline_commands: offline_commands,
         affected_paths: affected,
         rehearsals: rehearsals,
         catalog_sha256: catalog.sha256
       }}
    end
  end

  def readiness_commands(plan, changed_paths) do
    _admission_changed_paths = changed_paths
    credo = ["python3 -B scripts/check/changed_credo.py"]
    tests = plan.offline_commands
    ["mix format"] ++ credo ++ tests ++ plan.rehearsals ++ ["mix format"]
  end

  def handoff_valid?(plan, catalog, root \\ File.cwd!()) do
    rehearsal_ids =
      catalog.entries
      |> Enum.filter(& &1["provider_backed"])
      |> MapSet.new(&get_in(&1, ["rehearsal", "id"]))

    if Enum.all?(plan.offline, fn selector ->
         MapSet.member?(rehearsal_ids, selector) or File.exists?(Path.join(root, selector))
       end),
       do: :ok,
       else: {:error, "scenario proof selector is still missing at Developer handoff"}
  end

  def unchanged?(catalog), do: File.read(catalog.path) == {:ok, catalog.bytes}

  def trace(identity) when is_binary(identity) do
    case System.get_env("KOGEN_REHEARSAL_TRACE") do
      nil -> :ok
      path -> File.write!(path, identity <> "\n", [:append])
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_catalog(entries) do
    names = Enum.map(entries, & &1["name"])
    ranks = Enum.map(entries, & &1["rank"])

    valid =
      entries != [] and Enum.all?(entries, &valid_entry?/1) and
        names |> Enum.uniq() |> length() == length(names) and
        ranks |> Enum.uniq() |> length() == length(ranks) and "check" in names and
        Enum.all?(@aggregate_names, &(&1 not in names)) and
        Enum.all?(entries, fn entry -> Enum.all?(entry["depends_on"], &(&1 in names)) end) and
        Enum.all?(entries, fn
          %{"name" => "check", "depends_on" => []} -> true
          %{"name" => "check"} -> false
          entry -> "check" in entry["depends_on"]
        end)

    if valid and acyclic?(entries),
      do: :ok,
      else: {:error, "verification target catalog is incomplete or contradictory"}
  end

  defp validate_declared_targets(entries, root) do
    makefile = Path.join(root, "Makefile")

    case File.read(makefile) do
      {:ok, bytes} ->
        declared =
          ~r/^([A-Za-z0-9_.-]+)\s*:(?!=)/m
          |> Regex.scan(bytes)
          |> Enum.map(fn [_, name] -> name end)
          |> MapSet.new()
          |> MapSet.delete(".PHONY")

        cataloged = MapSet.new(entries, & &1["name"])

        if MapSet.equal?(declared, cataloged),
          do: :ok,
          else: {:error, "verification target catalog does not match declared Make targets"}

      {:error, reason} ->
        {:error, "could not read Makefile for verification target inventory: #{inspect(reason)}"}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_entry?(entry) do
    is_map(entry) and is_binary(entry["name"]) and entry["name"] != "" and
      is_binary(entry["cost_class"]) and is_integer(entry["rank"]) and entry["rank"] >= 0 and
      is_list(entry["depends_on"]) and is_boolean(entry["provider_backed"]) and
      present?(entry["owner"]) and valid_rehearsal?(entry)
  end

  defp valid_rehearsal?(%{"provider_backed" => false} = entry),
    do: Map.get(entry, "rehearsal") in [nil, "none"]

  defp valid_rehearsal?(%{"provider_backed" => true, "rehearsal" => rehearsal})
       when is_map(rehearsal) do
    Enum.all?(
      ~w(id command shared_entrypoints correct_fixture wrong_fixture trace_assertions),
      fn key ->
        value = rehearsal[key]

        (is_binary(value) and String.trim(value) != "") or
          (is_list(value) and value != [] and
             Enum.all?(value, &(is_binary(&1) and String.trim(&1) != "")))
      end
    )
  end

  defp valid_rehearsal?(_), do: false

  defp present?(value),
    do: (is_binary(value) and String.trim(value) != "") or (is_list(value) and value != [])

  defp normalize_entry(entry) when is_map(entry),
    do: Map.put(entry, "depends_on", entry["depends_on"] || entry["dependencies"] || [])

  defp validate_proofs(scenarios, guards, catalog, root) do
    if Enum.all?(scenarios, &valid_proof?(&1, guards, catalog, root)),
      do: :ok,
      else: {:error, "scenario proof map is missing, unsafe, or inconsistent"}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_proof?(scenario, guards, catalog, root) do
    proof = scenario["proof"]
    target = is_map(proof) && proof["paid_target"]
    offline = is_map(proof) && proof["offline"]
    affected = is_map(proof) && proof["affected_paths"]

    is_list(offline) and offline != [] and
      Enum.all?(offline, &valid_selector?(&1, root, affected, catalog)) and
      is_list(affected) and affected != [] and Enum.all?(affected, &guarded?(&1, guards)) and
      (target == "none" or
         (is_binary(target) and target != "check" and Map.has_key?(catalog.targets, target))) and
      valid_reason?(proof["paid_reason"], target, catalog) and
      scenario["verified_by"] == ["check"] ++ if(target == "none", do: [], else: [target])
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_selector?(selector, root, affected, catalog) when is_binary(selector) do
    rehearsal? = Enum.any?(catalog.entries, &(get_in(&1, ["rehearsal", "id"]) == selector))
    clean = Path.expand(selector, root)
    relative = Path.relative_to(clean, root)

    broad =
      selector in [".", "test", "test/", "test/**", "test/**/*"] or
        String.contains?(selector, "*") or (String.contains?(selector, ":") and not rehearsal?)

    inside =
      relative != ".." and not String.starts_with?(relative, "../") and
        Path.type(selector) == :relative

    exists_or_planned =
      File.exists?(clean) or Enum.any?(affected || [], &path_matches?(selector, &1))

    rehearsal? or (inside and not broad and exists_or_planned)
  end

  defp valid_selector?(_, _, _, _), do: false

  defp valid_reason?(reason, "none", _catalog),
    do: is_binary(reason) and Regex.match?(~r/^offline-sufficient: \S.+$/, reason)

  defp valid_reason?(reason, target, catalog) when is_binary(reason) do
    entry = catalog.targets[target]

    entry && (entry["provider_backed"] == true or target == "cold-offline") &&
      Regex.match?(
        ~r/^provider-required: #{Regex.escape(target)}; observation: \S.+; offline-limit: \S.+$/,
        reason
      )
  end

  defp valid_reason?(_, _, _), do: false

  defp guarded?(path, guards), do: Enum.any?(guards, &path_matches?(path, &1))

  defp path_matches?(path, guard) do
    regex =
      guard |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
  end

  defp selected_order(selected, catalog) do
    entries = Enum.map(selected, &catalog.targets[&1])

    if Enum.all?(entries, fn entry ->
         Enum.all?(entry["depends_on"], &(&1 == "check" or &1 in selected))
       end) do
      case order(entries) do
        {:ok, ordered} -> {:ok, Enum.map(ordered, & &1["name"])}
        error -> error
      end
    else
      {:error, "selected verification target has an unselected dependency"}
    end
  end

  defp order(entries) do
    names = MapSet.new(Enum.map(entries, & &1["name"]))
    sorted = Enum.sort_by(entries, &{&1["rank"], &1["name"]})
    topo(sorted, names, [], MapSet.new())
  end

  defp topo([], _names, acc, _done), do: {:ok, Enum.reverse(acc)}

  defp topo(pending, names, acc, done) do
    case Enum.split_with(pending, fn entry ->
           Enum.all?(
             entry["depends_on"],
             &(&1 == "check" or &1 not in names or MapSet.member?(done, &1))
           )
         end) do
      {[], _} ->
        {:error, "verification target dependency cycle"}

      {ready, rest} ->
        topo(
          rest,
          names,
          Enum.reverse(ready) ++ acc,
          Enum.reduce(ready, done, &MapSet.put(&2, &1["name"]))
        )
    end
  end

  defp acyclic?(entries), do: match?({:ok, _}, order(entries))

  defp selector_command(selector, catalog) do
    case Enum.find(catalog.entries, &(get_in(&1, ["rehearsal", "id"]) == selector)) do
      nil -> "mix test " <> shell_quote(selector)
      entry -> get_in(entry, ["rehearsal", "command"])
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
