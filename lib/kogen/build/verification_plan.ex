defmodule Kogen.Build.VerificationPlan do
  @moduledoc """
  Loads and freezes either the target project's declared checks or the
  repository verification catalog, then plans scenario proof and readiness.
  """

  @catalog_path "priv/kogen/verification_targets.yaml"
  @aggregate_names ~w(live live-all)
  # Controller volatile state a base workspace must never inherit.
  @volatile_paths ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions)
  import Bitwise, only: [band: 2]
  alias Kogen.Check.MakeInventory

  @doc "Repository-relative path of the verification-target catalog."
  def catalog_path, do: @catalog_path

  @doc """
  Loads the project-owned checks in `root` when `.kogen/project.yaml` exists;
  otherwise it loads and validates the engine catalog. The engine catalog
  may declare the integrity fields `verification_surface` (`tests` and
  `runner` globs), `focused_runner` (an argv template with one `{paths}`
  element) and `base_cache` (paths copied into the base workspace). They are
  present together or not at all; without them `integrity` is `nil`.
  """
  def load(root \\ File.cwd!()) do
    if project_config_present?(root) do
      load_project_catalog(root)
    else
      load_engine_catalog(root)
    end
  end

  defp load_engine_catalog(root) do
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

  defp load_project_catalog(root) do
    with {:ok, project} <- Kogen.Check.open_project(root),
         {:ok, bytes} <- File.read(project.config_path),
         true <- sha256(bytes) == project.config_sha256,
         {:ok, entries} <- project_entries(project.checks),
         :ok <- validate_catalog(entries),
         {:ok, ordered} <- order(entries) do
      targets = Map.new(entries, &{&1["name"], &1})

      {:ok,
       %{
         path: project.config_path,
         bytes: bytes,
         sha256: project.config_sha256,
         commands_sha256: project.commands_sha256,
         entries: entries,
         targets: targets,
         ordered_targets: Enum.map(ordered, & &1["name"]),
         integrity: nil,
         project_root: project.root,
         engine_root: project.engine_root
       }}
    else
      false ->
        {:error, "project.yaml changed while its check commands were being resolved"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "could not load project check configuration: #{inspect(reason)}"}

      _ ->
        {:error, "project check configuration is malformed"}
    end
  end

  defp project_config_present?(root) do
    path = Path.join([Path.expand(root), ".kogen", "project.yaml"])

    case File.lstat(path) do
      {:ok, _info} -> true
      {:error, _reason} -> false
    end
  end

  defp project_entries(checks) do
    checks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {check, rank}, {:ok, entries} ->
      name = check["name"]

      if Kogen.Check.valid_target_name?(name) do
        entry = %{
          "name" => name,
          "argv" => check["argv"],
          "cost_class" => "project",
          "rank" => rank,
          "depends_on" => [],
          "provider_backed" => false,
          "owner" => "project",
          "rehearsal" => nil
        }

        {:cont, {:ok, [entry | entries]}}
      else
        {:halt,
         {:error, "project check name is not a safe verification target: #{inspect(name)}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  @doc "Resolves a frozen project check executable into the Candidate checkout."
  def command(%{project_root: project_root, targets: targets}, target, candidate_root) do
    case Map.get(targets, target) do
      %{"argv" => [executable | args]} ->
        with true <- Kogen.Check.valid_target_name?(target),
             {:ok, argv} <- rebind_project_argv([executable | args], project_root, candidate_root) do
          {:ok, argv}
        else
          false -> {:error, "refused unsafe project check name: #{inspect(target)}"}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "project check is missing from the frozen catalog: #{inspect(target)}"}
    end
  end

  def command(_catalog, target, _candidate_root),
    do: {:error, "target is not a frozen project check: #{inspect(target)}"}

  defp candidate_executable(executable, project_root, candidate_root) do
    executable = Path.expand(executable)

    if within?(executable, project_root) do
      relative = Path.relative_to(executable, project_root)
      candidate = relative |> Path.expand(candidate_root) |> Kogen.ProjectScope.canonical()

      if within?(candidate, candidate_root) do
        validate_executable(candidate, "Candidate project executable is unavailable")
      else
        {:error, "Candidate project executable escapes its checkout: #{relative}"}
      end
    else
      validate_executable(executable, "frozen project executable is unavailable")
    end
  end

  defp canonical_directory(path) do
    canonical = Kogen.ProjectScope.canonical(path)

    case File.stat(canonical) do
      {:ok, %{type: :directory}} -> {:ok, canonical}
      _ -> {:error, "Candidate project root is not an available directory: #{path}"}
    end
  end

  defp validate_executable(path, message) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when band(mode, 0o111) != 0 ->
        {:ok, path}

      _ ->
        {:error, "#{message}: #{path}"}
    end
  end

  defp within?(path, root) do
    path_parts = Path.split(Path.expand(path))
    root_parts = Path.split(Path.expand(root))
    Enum.take(path_parts, length(root_parts)) == root_parts
  end

  defp rebind_project_argv([executable | args], project_root, candidate_root) do
    with {:ok, candidate_root} <- canonical_directory(candidate_root),
         {:ok, executable} <- candidate_executable(executable, project_root, candidate_root) do
      {:ok, [executable | args]}
    end
  end

  defp rebind_project_argv(_argv, _project_root, _candidate_root),
    do: {:error, "frozen project check argv is malformed"}

  defp project_commands(targets, %{project_root: _root} = catalog) do
    Map.new(targets, &{&1, catalog.targets[&1]["argv"]})
  end

  defp project_commands(_targets, _catalog), do: %{}

  @doc """
  Builds the plan. `verified_by` is the complete, explicit list of targets a
  scenario needs; the plan runs exactly the union of those lists in catalog
  rank order and never adds a target. `proof.paid_target` names the primary
  provider-backed target (or the cataloged `cold-offline` target); any other
  explicitly listed provider-backed targets are still required and carry
  their own receipt evidence. Duplicate names and input ordering are
  canonicalized in the planned union. `opts[:added]`
  names targets the Intent declares in `catalog_changes.add`: they may be
  selected although the admission catalog lacks them, and their catalog rules
  are checked each cycle against the Candidate's catalog.
  """
  def build(scenarios, guards, catalog, root \\ File.cwd!(), opts \\ [])
      when is_list(scenarios) and is_list(guards) and is_map(catalog) do
    added = Keyword.get(opts, :added, [])

    with :ok <- validate_added(added, catalog),
         :ok <- validate_proofs(scenarios, guards, catalog, root, added),
         selected = scenarios |> Enum.flat_map(& &1["verified_by"]) |> Enum.uniq(),
         {:ok, ordered} <- selected_order(selected, catalog.targets, added),
         :ok <- maybe_validate_coverage(ordered, scenarios, catalog, opts) do
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
         commands_sha256: Map.get(catalog, :commands_sha256),
         project_root: Map.get(catalog, :project_root),
         project_commands: project_commands(ordered, catalog),
         login_roles: login_roles(ordered, catalog),
         scenarios: Enum.map(scenarios, &scenario_proof(&1, catalog))
       }}
    end
  end

  @doc "Harnesses needed by the roles that selected route-marked targets launch."
  def required_logins(plan, config) do
    plan.login_roles
    |> Enum.map(&Kogen.Intent.role_harness(config, &1))
    |> Enum.uniq()
  end

  defp login_roles(targets, catalog) do
    targets
    |> Enum.flat_map(fn target ->
      case catalog.targets[target] do
        %{"requires_login" => "route", "launched_roles" => roles} ->
          Enum.map(roles, &String.to_existing_atom/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp validate_coverage(targets, scenarios, catalog) do
    affected =
      scenarios |> Enum.flat_map(&get_in(&1, ["proof", "affected_paths"])) |> MapSet.new()

    selected = MapSet.new(targets)

    marked = Enum.filter(catalog.entries, &(is_list(&1["covers"]) and &1["covers"] != []))

    overbroad =
      Enum.find(marked, fn entry ->
        MapSet.member?(selected, entry["name"]) and
          not Enum.any?(entry["covers"], &MapSet.member?(affected, &1))
      end)

    uncovered =
      Enum.find(affected, fn path ->
        owners = Enum.filter(marked, &(path in &1["covers"]))
        owners != [] and not Enum.any?(owners, &MapSet.member?(selected, &1["name"]))
      end)

    cond do
      overbroad ->
        {:error, "selected provider target #{overbroad["name"]} covers no affected path"}

      uncovered ->
        {:error, "changed-path coverage missing selected target for #{uncovered}"}

      true ->
        :ok
    end
  end

  # Earlier Approved and Complete packages predate coverage metadata, so
  # declared-path coverage is checked only on request; keep them readable.
  # Actual changed owners are disclosed to Review by `review_disclosures/5`.
  defp maybe_validate_coverage(targets, scenarios, catalog, opts) do
    if Keyword.get(opts, :strict_coverage, false),
      do: validate_coverage(targets, scenarios, catalog),
      else: :ok
  end

  @doc "Required catalog owners for actual changed paths, using the frozen target selection."
  def missing_changed_coverage(plan, catalog, changed_paths) do
    selected = MapSet.new(plan.targets)

    catalog.entries
    |> Enum.filter(fn entry ->
      entry["provider_backed"] == true and
        Enum.any?(List.wrap(entry["covers"]), &(&1 in changed_paths)) and
        not MapSet.member?(selected, entry["name"])
    end)
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  @doc """
  Builds advisory disclosures for the independent Reviewer. Declared test names
  and catalog coverage mappings are context only; actual required proof remains
  the selected target receipts and the scenario's required offline selectors.
  """
  def review_disclosures(scenarios, plan, catalog, changed_paths, root \\ File.cwd!()) do
    {missing_names, enumeration_error} =
      case missing_tests(scenarios, root) do
        {:ok, names} -> {MapSet.new(names), nil}
        {:error, reason} -> {MapSet.new(), reason}
      end

    test_name_mappings =
      scenarios
      |> Enum.map(fn scenario ->
        names = scenario |> Map.get("tests", []) |> List.wrap() |> Enum.uniq()

        %{
          "scenario_id" => scenario["id"],
          "declared_names" => names,
          "absent_names" => Enum.filter(names, &MapSet.member?(missing_names, &1))
        }
      end)
      |> Enum.reject(&(&1["declared_names"] == []))

    selected = MapSet.new(plan.targets)

    {changed, changed_paths_error} =
      case changed_paths do
        paths when is_list(paths) -> {MapSet.new(paths), nil}
        {:ok, paths} when is_list(paths) -> {MapSet.new(paths), nil}
        {:error, reason} -> {MapSet.new(), reason}
      end

    changed_provider_coverage_gaps =
      catalog.entries
      |> Enum.filter(fn entry ->
        entry["provider_backed"] == true and not MapSet.member?(selected, entry["name"])
      end)
      |> Enum.map(fn entry ->
        paths = Enum.filter(List.wrap(entry["covers"]), &MapSet.member?(changed, &1))
        {entry["name"], paths}
      end)
      |> Enum.reject(fn {_target, paths} -> paths == [] end)
      |> Enum.map(fn {target, paths} -> %{"target" => target, "paths" => paths} end)

    %{
      "disposition" =>
        "advisory only: assess current scenario evidence; declared test names and path mappings are not proof",
      "test_name_mappings" => %{
        "scenarios" => test_name_mappings,
        "enumeration_error" => enumeration_error
      },
      "changed_provider_coverage_gaps" => changed_provider_coverage_gaps,
      "changed_paths_error" => changed_paths_error
    }
  end

  @doc """
  Every proof error `build/4,5` would refuse for `scenarios`, collecting all
  violated predicates instead of short-circuiting.
  """
  def proof_errors(scenarios, guards, catalog, root, opts \\ [])
      when is_list(scenarios) and is_list(guards) and is_map(catalog) do
    added = Keyword.get(opts, :added, [])

    added_errors =
      case validate_added(added, catalog) do
        :ok -> []
        {:error, reason} -> [{"verified-by-invalid", reason}]
      end

    added_errors ++
      Enum.flat_map(scenarios, &scenario_proof_errors(&1, guards, catalog, root, added))
  end

  defp scenario_proof_errors(scenario, guards, catalog, root, added) do
    proof = scenario["proof"]

    if is_map(proof) do
      affected_value = proof["affected_paths"]
      offline_value = proof["offline"]
      affected = if is_list(affected_value), do: affected_value, else: []
      offline = if is_list(offline_value), do: offline_value, else: []
      target = proof["paid_target"]

      shape_errors =
        nonempty_list_error(offline_value, "proof.offline") ++
          nonempty_list_error(affected_value, "proof.affected_paths") ++
          target_error(target, catalog, added) ++
          base_error(proof["base"])

      guard_errors =
        for path <- affected, not guarded?(path, guards), do: {"unguarded-affected-path", path}

      selector_errors =
        if is_list(offline_value),
          do: Enum.flat_map(offline, &selector_errors(&1, root, affected, catalog)),
          else: []

      reason_errors =
        if valid_reason?(proof["paid_reason"], target, catalog, added),
          do: [],
          else: [{"paid-reason-malformed", proof["paid_reason"] || "(missing)"}]

      verified_errors =
        scenario
        |> verified_by_errors(catalog.targets, added)
        |> Enum.flat_map(&verified_by_error_kinds/1)

      shape_errors ++ guard_errors ++ selector_errors ++ reason_errors ++ verified_errors
    else
      [{"verified-by-invalid", "scenario has no proof map"}]
    end
  end

  defp nonempty_list_error(value, _field) when is_list(value) and value != [], do: []

  defp nonempty_list_error(_value, field),
    do: [{"verified-by-invalid", "#{field} must be a nonempty list"}]

  defp target_error("none", _catalog, _added), do: []

  defp target_error(target, catalog, added)
       when is_binary(target) do
    if Map.has_key?(catalog.targets, target) or target in added,
      do: [],
      else: [{"verified-by-invalid", "proof.paid_target names an unknown target: #{target}"}]
  end

  defp target_error(_target, _catalog, _added),
    do: [{"verified-by-invalid", "proof.paid_target must be none or a target name"}]

  defp base_error(base) when base in [nil, "fail", "pass"], do: []
  defp base_error(_base), do: [{"verified-by-invalid", "proof.base must be nil, fail, or pass"}]

  defp verified_by_error_kinds(message) do
    if String.contains?(message, "unknown target") do
      for name <- unknown_target_names(message), do: {"unknown-target", name}
    else
      [{"verified-by-invalid", message}]
    end
  end

  defp unknown_target_names(message) do
    message |> String.split(": ", parts: 2) |> List.last() |> String.split(", ")
  end

  @broad_selector_forms [".", "test", "test/", "test/**", "test/**/*"]

  defp selector_errors(selector, root, affected, catalog) do
    if valid_selector?(selector, root, affected, catalog),
      do: [],
      else: [selector_error(selector, root, catalog)]
  end

  defp selector_error(selector, _root, _catalog) when not is_binary(selector),
    do: {"unsupported-selector", inspect(selector)}

  defp selector_error(selector, _root, catalog) do
    if unsupported_selector_form?(selector, catalog),
      do: {"unsupported-selector", selector},
      else: {"proof-selector-missing", selector}
  end

  defp unsupported_selector_form?(selector, catalog) do
    selector in @broad_selector_forms or String.contains?(selector, "*") or
      (String.contains?(selector, ":") and not rehearsal_selector?(selector, catalog)) or
      Path.type(selector) == :absolute or ".." in Path.split(selector)
  end

  defp rehearsal_selector?(selector, catalog),
    do: Enum.any?(catalog.entries, &(get_in(&1, ["rehearsal", "id"]) == selector))

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
  admission); rules that need their entry are checked once it exists. The
  scalar `proof.paid_target` must identify the primary selected paid target
  (with `cold-offline` as the cataloged offline-cost exception); other selected
  provider-backed targets are allowed and remain required.
  Duplicate or out-of-order target names are accepted because `build/5`
  canonicalizes the selected union. Returns the list of violated rules.
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

      [
        {missing == [], "verified_by names an unknown target: #{Enum.join(missing, ", ")}"},
        {offline != [] or pending?, "verified_by needs at least one offline target"},
        {(target == "none" and paid == []) or target in paid or
           (target == "cold-offline" and paid == [] and target in list) or target in unknown,
         "proof.paid_target must name the primary listed paid target"},
        {target == "none" or target in list, "proof.paid_target is not listed in verified_by"},
        {Enum.all?(known, fn entry -> Enum.all?(entry["depends_on"], &(&1 in list)) end),
         "verified_by omits a dependency of a listed target"}
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
      "affected_paths" => get_in(scenario, ["proof", "affected_paths"]) || [],
      "base" => base,
      "label" => proof_label(catalog, base),
      "file_selectors" => files,
      "existence_selectors" => others,
      "selector_commands" => Enum.map(offline, &selector_command(&1, catalog))
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

  @doc "Focused development observations for the current changed paths; never gate receipts."
  def readiness_commands(plan, changed_paths, root \\ File.cwd!()) do
    if is_binary(Map.get(plan, :project_root)) do
      project_readiness_commands(plan, root)
    else
      engine_readiness_commands(plan, changed_paths, root)
    end
  end

  defp engine_readiness_commands(plan, changed_paths, root) do
    relevant_scenarios =
      Enum.filter(plan.scenarios, fn scenario ->
        affected = Map.get(scenario, "affected_paths", [])
        Enum.any?(changed_paths, &(&1 in affected))
      end)

    tests =
      relevant_scenarios
      |> Enum.flat_map(&Map.get(&1, "selector_commands", []))
      |> Enum.uniq()

    changed_tests =
      changed_paths
      |> Enum.filter(&String.starts_with?(&1, "lib/"))
      |> Enum.map(fn path ->
        path
        |> String.replace_prefix("lib/", "test/")
        |> String.replace_suffix(".ex", "_test.exs")
      end)
      |> Enum.filter(&File.regular?(Path.join(root, &1)))
      |> Enum.uniq()
      |> Enum.map(&"mix test '#{&1}'")

    ["mix format", "python3 -B scripts/check/changed_credo.py"] ++
      Enum.uniq(changed_tests ++ tests)
  end

  defp project_readiness_commands(plan, candidate_root) do
    Enum.map(plan.targets, fn target ->
      argv = Map.get(plan.project_commands, target)

      case rebind_project_argv(argv, plan.project_root, candidate_root) do
        {:ok, resolved} -> Enum.map_join(resolved, " ", &shell_quote/1)
        {:error, reason} -> "project check #{target} is unavailable: #{reason}"
      end
    end)
  end

  @doc "Exact optional `tests:` names absent from the Candidate's non-live dry run."
  def missing_tests(scenarios, root) do
    names =
      scenarios
      |> Enum.flat_map(&List.wrap(&1["tests"]))
      |> Enum.uniq()

    if names == [] do
      {:ok, []}
    else
      path =
        Path.join(System.tmp_dir!(), "kogen-tests-#{System.unique_integer([:positive])}.jsonl")

      try do
        {_output, status} =
          System.cmd(
            "mix",
            ["test", "--dry-run", "--exclude", "live", "--formatter", "Kogen.TimingFormatter"],
            cd: root,
            stderr_to_stdout: true,
            env: [
              {"KOGEN_TEST_EVENT_LOG", path},
              {"KOGEN_TEST_ROOT", root},
              {"KOGEN_TEST_DRY_RUN", "1"},
              {"KOGEN_TEST_EVENT_OWNER_PID", nil},
              {"KOGEN_TEST_EVENT_OWNER_PATH", nil}
            ]
          )

        if status == 0 and File.regular?(path) do
          present =
            path
            |> File.stream!()
            |> Enum.flat_map(fn line ->
              case Jason.decode(line) do
                {:ok, %{"name" => name, "status" => "enumerated"}} -> [name]
                _ -> []
              end
            end)
            |> MapSet.new()

          {:ok, Enum.reject(names, &MapSet.member?(present, &1))}
        else
          {:error, "could not enumerate declared tests before Review"}
        end
      after
        File.rm(path)
      end
    end
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

  def unchanged?(%{project_root: root, engine_root: engine} = catalog) do
    with {:ok, bytes} <- File.read(catalog.path),
         true <- bytes == catalog.bytes,
         {:ok, project} <- Kogen.Check.open_project(root),
         true <- project.engine_root == engine,
         true <- project.commands_sha256 == catalog.commands_sha256 do
      true
    else
      _ -> false
    end
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
    with :ok <- validate_prepare_shapes(entries) do
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
  end

  # A named, specific error for an invalid `prepare` shape, ahead of the
  # generic catalog-consistency check.
  defp validate_prepare_shapes(entries) do
    case Enum.find(entries, &(not valid_prepare?(&1))) do
      nil ->
        :ok

      entry ->
        {:error,
         "verification target #{inspect(entry["name"])}: prepare must be a nonempty argv list of nonempty strings"}
    end
  end

  # Every catalog target must exist in the Makefile as an ordinary
  # single-colon rule; other Makefile targets are allowed. A pattern or
  # double-colon rule is refused only when it could define or shadow a
  # catalog target's name.
  defp validate_declared_targets(entries, root) do
    makefile = Path.join(root, "Makefile")
    cataloged = Enum.map(entries, & &1["name"])

    case MakeInventory.load(makefile) do
      {:ok, %{targets: declared, unsupported: unsupported}} ->
        with :ok <- require_ordinary_targets(cataloged, declared) do
          require_no_shadow(unsupported, cataloged)
        end

      {:error, reason} ->
        {:error, "could not read Makefile for verification target inventory: #{reason}"}
    end
  end

  defp require_ordinary_targets(cataloged, declared) do
    case Enum.find(cataloged, &(not MapSet.member?(declared, &1))) do
      nil ->
        :ok

      missing ->
        {:error,
         "verification target catalog target #{inspect(missing)} has no ordinary Make rule"}
    end
  end

  defp require_no_shadow(unsupported, cataloged) do
    cataloged_set = MapSet.new(cataloged)

    shadow =
      Enum.find_value(unsupported, fn rule ->
        case shadowed_target(rule, cataloged_set) do
          nil -> nil
          target -> {rule, target}
        end
      end)

    case shadow do
      nil ->
        :ok

      {rule, target} ->
        kind = if rule.kind == :double_colon, do: "double-colon", else: "pattern"

        {:error,
         "#{kind} Make rule at line #{rule.line} could shadow catalog target #{inspect(target)}"}
    end
  end

  defp shadowed_target(%{kind: :double_colon, names: names}, cataloged_set) do
    Enum.find(names, &MapSet.member?(cataloged_set, &1))
  end

  defp shadowed_target(%{kind: :pattern, names: names}, cataloged_set) do
    Enum.find_value(names, fn name ->
      Enum.find(cataloged_set, &pattern_matches?(name, &1))
    end)
  end

  defp pattern_matches?(pattern, target) do
    if String.contains?(pattern, "%") do
      regex =
        pattern
        |> String.split("%")
        |> Enum.map_join(".*", &Regex.escape/1)
        |> then(&Regex.compile!("^#{&1}$"))

      Regex.match?(regex, target)
    else
      pattern == target
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
      present?(entry["owner"]) and valid_rehearsal?(entry) and valid_prepare?(entry) and
      valid_same_tree_retry?(entry) and valid_route_metadata?(entry)
  end

  # Optional `same_tree_retry`: 0 or 1 rerun of a failed provider-backed
  # target on the identical Candidate tree.
  defp valid_same_tree_retry?(entry) do
    case Map.get(entry, "same_tree_retry") do
      nil -> true
      0 -> true
      1 -> entry["provider_backed"] == true
      _other -> false
    end
  end

  defp valid_route_metadata?(entry) do
    case entry["requires_login"] do
      nil ->
        is_nil(entry["covers"]) and is_nil(entry["launched_roles"])

      "route" ->
        entry["provider_backed"] == true and valid_route_coverage?(entry["covers"]) and
          valid_route_roles?(entry["launched_roles"])

      _ ->
        false
    end
  end

  defp valid_route_coverage?(covers),
    do: is_list(covers) and covers != [] and Enum.all?(covers, &safe_relative?/1)

  defp valid_route_roles?(roles),
    do:
      is_list(roles) and roles != [] and
        Enum.all?(roles, &(&1 in ~w(shaping developer reviewer expert)))

  # An optional `prepare` is a nonempty argv list of nonempty strings (no
  # shell); any other shape is refused. Absent is valid: the controller does
  # not require `prepare` (scenario `controller-runs-prepare-before-paid`).
  defp valid_prepare?(entry) do
    case Map.get(entry, "prepare") do
      nil ->
        true

      list when is_list(list) and list != [] ->
        Enum.all?(list, &(is_binary(&1) and &1 != ""))

      _other ->
        false
    end
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
