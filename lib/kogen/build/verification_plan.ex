defmodule Kogen.Build.VerificationPlan do
  @moduledoc """
  Loads and freezes the repository verification-target catalog and turns the
  scenario proof declarations into one deterministic execution/readiness plan.
  """

  @catalog_path "priv/kogen/verification_targets.yaml"
  @aggregate_names ~w(live live-all)
  # Controller volatile state a base workspace must never inherit.
  @volatile_paths ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions)
  alias Kogen.Check.MakeInventory

  @doc "Repository-relative path of the verification-target catalog."
  def catalog_path, do: @catalog_path

  @doc """
  Loads and validates the catalog in `root`. Besides the targets, a catalog
  may declare the integrity fields `verification_surface` (`tests` and
  `runner` globs), `focused_runner` (an argv template with one `{paths}`
  element) and `base_cache` (paths copied into the base workspace). They are
  present together or not at all; without them `integrity` is `nil`.
  """
  def load(root \\ File.cwd!()) do
    path = Path.join(root, @catalog_path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(bytes),
         entries when is_list(entries) <- targets_of(decoded),
         entries <- Enum.map(entries, &normalize_entry/1),
         :ok <- validate_catalog(entries),
         :ok <- validate_declared_targets(entries, root),
         {:ok, integrity} <- integrity(decoded),
         {:ok, ordered} <- order(entries) do
      targets = Map.new(entries, &{&1["name"], &1})

      {:ok,
       %{
         path: path,
         bytes: bytes,
         sha256: sha256(bytes),
         entries: entries,
         targets: targets,
         ordered_targets: Enum.map(ordered, & &1["name"]),
         integrity: integrity
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

  @doc """
  Builds the plan. `verified_by` is the complete, explicit list of targets a
  scenario needs; the plan runs exactly the union of those lists in catalog
  rank order and never adds a target. `opts[:added]` names targets the
  Intent declares in `catalog_changes.add`: they may be selected although the
  admission catalog lacks them, and their catalog rules are checked each
  cycle against the Candidate's catalog.
  """
  def build(scenarios, guards, catalog, root \\ File.cwd!(), opts \\ [])
      when is_list(scenarios) and is_list(guards) and is_map(catalog) do
    added = Keyword.get(opts, :added, [])

    with :ok <- validate_added(added, catalog),
         :ok <- validate_proofs(scenarios, guards, catalog, root, added),
         selected = scenarios |> Enum.flat_map(& &1["verified_by"]) |> Enum.uniq(),
         {:ok, ordered} <- selected_order(selected, catalog.targets, added) do
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
         targets: ordered,
         added: added,
         offline: offline,
         offline_commands: offline_commands,
         affected_paths: affected,
         rehearsals: rehearsals,
         catalog_sha256: catalog.sha256,
         scenarios: Enum.map(scenarios, &scenario_proof(&1, catalog))
       }}
    end
  end

  @doc """
  Orders `names` by catalog rank using `entries` (name to catalog entry), with
  dependencies first. Every name must have an entry.
  """
  def order_names(names, entries) when is_list(names) and is_map(entries) do
    if Enum.all?(names, &Map.has_key?(entries, &1)) do
      case order(Enum.map(names, &entries[&1])) do
        {:ok, ordered} -> {:ok, Enum.map(ordered, & &1["name"])}
        error -> error
      end
    else
      {:error, "selected verification target is missing from the catalog"}
    end
  end

  @doc """
  The `verified_by` rules for one scenario against `entries` (name to catalog
  entry). `unknown` names may be absent from `entries` (declared additions at
  admission); rules that need their entry are checked once it exists.
  Returns the list of violated rules.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def verified_by_errors(scenario, entries, unknown \\ []) do
    list = scenario["verified_by"]
    target = get_in(scenario, ["proof", "paid_target"])

    if is_list(list) and list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")) do
      known = for name <- list, Map.has_key?(entries, name), do: entries[name]
      missing = Enum.reject(list, &(Map.has_key?(entries, &1) or &1 in unknown))
      pending? = Enum.any?(list, &(not Map.has_key?(entries, &1)))
      paid = for entry <- known, entry["provider_backed"] == true, do: entry["name"]
      offline = for entry <- known, entry["provider_backed"] == false, do: entry["name"]
      ranks = Enum.map(known, & &1["rank"])

      [
        {Enum.uniq(list) == list, "verified_by lists a target twice"},
        {missing == [], "verified_by names an unknown target: #{Enum.join(missing, ", ")}"},
        {offline != [] or pending?, "verified_by needs at least one offline target"},
        {length(paid) <= 1, "verified_by lists more than one provider-backed target"},
        {paid == [] or paid == [target],
         "verified_by provider-backed target must be proof.paid_target"},
        {target == "none" or target in list, "proof.paid_target is not listed in verified_by"},
        {Enum.all?(known, fn entry -> Enum.all?(entry["depends_on"], &(&1 in list)) end),
         "verified_by omits a dependency of a listed target"},
        {ranks == Enum.sort(ranks), "verified_by does not follow catalog rank order"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    else
      ["verified_by must be a nonempty list of target names"]
    end
  end

  @doc """
  The proof label of a planned scenario: `integrity-not-configured` when the
  admission catalog has no integrity fields, `unproven-on-base` for a
  contract without `proof.base`, otherwise `base-fail` or `base-pass`.
  """
  def proof_label(%{integrity: nil}, _base), do: "integrity-not-configured"
  def proof_label(_catalog, nil), do: "unproven-on-base"
  def proof_label(_catalog, base), do: "base-" <> base

  @doc """
  Whether `selector` is a file selector the controller runs (a test file or
  directory under `test/`), rather than an existence-checked rehearsal id,
  root `.txt` fixture or `scripts/check` file.
  """
  def file_selector?(selector, catalog) do
    not rehearsal_id?(selector, catalog) and String.starts_with?(selector, "test/") and
      (String.ends_with?(selector, "_test.exs") or
         not String.contains?(Path.basename(selector), "."))
  end

  defp rehearsal_id?(selector, catalog),
    do: Enum.any?(catalog.entries, &(get_in(&1, ["rehearsal", "id"]) == selector))

  defp scenario_proof(scenario, catalog) do
    base = get_in(scenario, ["proof", "base"])
    offline = get_in(scenario, ["proof", "offline"])
    {files, others} = Enum.split_with(offline, &file_selector?(&1, catalog))

    %{
      "id" => scenario["id"],
      "base" => base,
      "label" => proof_label(catalog, base),
      "file_selectors" => files,
      "existence_selectors" => others
    }
  end

  defp validate_added(added, catalog) do
    existing = Enum.filter(List.wrap(added), &Map.has_key?(catalog.targets, &1))

    cond do
      not (is_list(added) and Enum.all?(added, &Kogen.Check.valid_target_name?/1)) ->
        {:error, "catalog_changes.add must list safe target names"}

      Enum.uniq(added) != added ->
        {:error, "catalog_changes.add lists a target twice"}

      existing != [] ->
        {:error,
         "catalog_changes.add names a target that already exists: " <> Enum.join(existing, ", ")}

      true ->
        :ok
    end
  end

  def readiness_commands(plan, changed_paths) do
    _admission_changed_paths = changed_paths
    credo = ["python3 -B scripts/check/changed_credo.py"]
    tests = plan.offline_commands
    ["mix format"] ++ credo ++ tests ++ plan.rehearsals ++ ["mix format"]
  end

  def handoff_valid?(plan, catalog, root \\ File.cwd!()) do
    if missing_selectors(plan, catalog, root) == [],
      do: :ok,
      else: {:error, "scenario proof selector is still missing at Developer handoff"}
  end

  @doc """
  Declared offline proof selectors that still do not exist in the Candidate,
  in plan order. A provider-backed rehearsal id is never missing.
  """
  def missing_selectors(plan, catalog, root \\ File.cwd!()) do
    rehearsal_ids =
      catalog.entries
      |> Enum.filter(& &1["provider_backed"])
      |> MapSet.new(&get_in(&1, ["rehearsal", "id"]))

    Enum.reject(plan.offline, fn selector ->
      MapSet.member?(rehearsal_ids, selector) or File.exists?(Path.join(root, selector))
    end)
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
        ranks |> Enum.uniq() |> length() == length(ranks) and
        Enum.all?(@aggregate_names, &(&1 not in names)) and
        Enum.all?(entries, fn entry -> Enum.all?(entry["depends_on"], &(&1 in names)) end) and
        Enum.any?(entries, &(&1["provider_backed"] == false and &1["depends_on"] == []))

    if valid and acyclic?(entries),
      do: :ok,
      else: {:error, "verification target catalog is incomplete or contradictory"}
  end

  defp validate_declared_targets(entries, root) do
    makefile = Path.join(root, "Makefile")

    case MakeInventory.load(makefile) do
      {:ok, declared} ->
        cataloged = MapSet.new(entries, & &1["name"])

        if MapSet.equal?(declared, cataloged),
          do: :ok,
          else: {:error, "verification target catalog does not match declared Make targets"}

      {:error, reason} ->
        {:error, "could not read Makefile for verification target inventory: #{reason}"}
    end
  end

  @doc "Renders target declarations for a fixture Makefile from catalog entries."
  def render_target_declarations(entries) when is_list(entries) do
    entries
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join("\n", &(&1 <> ":\n\t@true"))
    |> Kernel.<>("\n")
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

  defp targets_of(%{"targets" => targets}), do: targets
  defp targets_of(decoded) when is_list(decoded), do: decoded
  defp targets_of(_decoded), do: nil

  @integrity_keys ~w(verification_surface focused_runner base_cache)

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp integrity(decoded) when is_map(decoded) do
    case Enum.filter(@integrity_keys, &Map.has_key?(decoded, &1)) do
      [] ->
        {:ok, nil}

      @integrity_keys ->
        surface = decoded["verification_surface"]
        runner = decoded["focused_runner"]
        cache = decoded["base_cache"] || []

        cond do
          not (is_map(surface) and globs?(surface["tests"]) and globs?(surface["runner"]) and
                   Enum.sort(Map.keys(surface)) == ["runner", "tests"]) ->
            {:error, "verification_surface must declare tests and runner glob lists"}

          not (is_list(runner) and runner != [] and Enum.all?(runner, &nonblank?/1) and
                   Enum.count(runner, &(&1 == "{paths}")) == 1) ->
            {:error, "focused_runner must be an argv list with exactly one {paths} element"}

          not (is_list(cache) and Enum.all?(cache, &safe_relative?/1)) ->
            {:error, "base_cache must list safe repository-relative paths"}

          Enum.any?(cache, &volatile?/1) ->
            {:error,
             "base_cache must not copy controller volatile state (#{Enum.join(@volatile_paths, ", ")})"}

          true ->
            {:ok,
             %{
               "verification_surface" => %{
                 "tests" => surface["tests"],
                 "runner" => surface["runner"]
               },
               "focused_runner" => runner,
               "base_cache" => cache
             }}
        end

      _partial ->
        {:error,
         "catalog integrity fields must be declared together: #{Enum.join(@integrity_keys, ", ")}"}
    end
  end

  defp integrity(_decoded), do: {:ok, nil}

  @doc "The controller volatile paths a `base_cache` entry must never name or contain."
  def volatile_paths, do: @volatile_paths

  defp volatile?(path) do
    clean = String.trim_trailing(path, "/")

    Enum.any?(@volatile_paths, fn volatile ->
      clean == volatile or String.starts_with?(clean, volatile <> "/") or
        String.starts_with?(volatile, clean <> "/") or clean in [".", ".kogen"]
    end)
  end

  defp globs?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &nonblank?/1)

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp safe_relative?(path) do
    nonblank?(path) and Path.type(path) == :relative and
      Enum.all?(Path.split(path), &(&1 not in ["..", "."])) and not String.contains?(path, "\\")
  end

  @doc "Whether repository-relative `path` matches glob `guard` (`*` within a segment, `**` across)."
  def path_matches?(path, guard) do
    regex =
      guard |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
  end

  defp normalize_entry(entry) when is_map(entry),
    do: Map.put(entry, "depends_on", entry["depends_on"] || entry["dependencies"] || [])

  defp validate_proofs(scenarios, guards, catalog, root, added) do
    if Enum.all?(scenarios, &valid_proof?(&1, guards, catalog, root, added)),
      do: :ok,
      else: {:error, "scenario proof map is missing, unsafe, or inconsistent"}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_proof?(scenario, guards, catalog, root, added) do
    proof = scenario["proof"]
    target = is_map(proof) && proof["paid_target"]
    offline = is_map(proof) && proof["offline"]
    affected = is_map(proof) && proof["affected_paths"]

    is_list(offline) and offline != [] and
      Enum.all?(offline, &valid_selector?(&1, root, affected, catalog)) and
      is_list(affected) and affected != [] and Enum.all?(affected, &guarded?(&1, guards)) and
      (target == "none" or
         (is_binary(target) and (Map.has_key?(catalog.targets, target) or target in added))) and
      valid_reason?(proof["paid_reason"], target, catalog, added) and
      Map.get(proof, "base") in [nil, "fail", "pass"] and
      verified_by_errors(scenario, catalog.targets, added) == []
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

    supported_test_source =
      (String.starts_with?(relative, "test/") and
         (String.ends_with?(relative, "_test.exs") or File.dir?(clean))) or
        relative in ["scripts/check/rehearsals.exs", "scripts/check/offline.py"]

    fixture_artifact =
      Path.dirname(relative) == "." and String.ends_with?(relative, ".txt")

    rehearsal? or
      (inside and not broad and (supported_test_source or fixture_artifact) and exists_or_planned)
  end

  defp valid_selector?(_, _, _, _), do: false

  defp valid_reason?(reason, "none", _catalog, _added),
    do: is_binary(reason) and Regex.match?(~r/^offline-sufficient: \S.+$/, reason)

  # An added target's catalog entry exists only in the Candidate; its
  # provider-backed rules are checked there each cycle.
  defp valid_reason?(reason, target, catalog, added) when is_binary(reason) do
    entry = catalog.targets[target]

    (target in added or
       (entry && (entry["provider_backed"] == true or target == "cold-offline"))) &&
      Regex.match?(
        ~r/^provider-required: #{Regex.escape(target)}; observation: \S.+; offline-limit: \S.+$/,
        reason
      )
  end

  defp valid_reason?(_, _, _, _), do: false

  defp guarded?(path, guards), do: Enum.any?(guards, &path_matches?(path, &1))

  # Added targets have no admission entry; they follow the admission-ordered
  # targets here and are ordered by the Candidate catalog each cycle.
  defp selected_order(selected, targets, added) do
    {pending, known} = Enum.split_with(selected, &(&1 in added))
    entries = Enum.map(known, &targets[&1])

    if Enum.all?(entries, fn entry -> Enum.all?(entry["depends_on"], &(&1 in selected)) end) do
      case order(entries) do
        {:ok, ordered} -> {:ok, Enum.map(ordered, & &1["name"]) ++ Enum.sort(pending)}
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
             &(&1 not in names or MapSet.member?(done, &1))
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
