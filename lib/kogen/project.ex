defmodule Kogen.Project do
  @moduledoc """
  Opens one target Git checkout and resolves its project-owned setup and check
  commands. The module reads configuration and Git state; it never runs setup
  or project checks.
  """
  use Boundary, deps: [Kogen.ProjectScope]
  import Bitwise, only: [band: 2]

  @config_relative ".kogen/project.yaml"
  @setup_keys ["argv", "requires"]
  @check_keys ["name", "argv"]

  @type command :: map()
  @type t :: map()

  @doc "Opens a target checkout and resolves its project-owned command contract."
  @spec open(Path.t(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def open(project_root, engine_root) do
    with {:ok, engine_root} <- canonical_engine(engine_root),
         {:ok, root} <- git_root(project_root),
         {:ok, config_path, bytes} <- read_project_config(root),
         {:ok, config} <- decode_config(bytes),
         {:ok, setup_spec, check_specs} <- validate_config(config),
         {:ok, setup} <- resolve_setup(setup_spec, root),
         {:ok, checks} <- resolve_checks(check_specs, root, setup),
         {:ok, git} <- git_state(root) do
      commands = %{setup: setup, checks: checks}

      {:ok,
       %{
         root: root,
         id: sha256(root),
         engine_root: engine_root,
         self_project?: root == engine_root,
         config_path: config_path,
         config_sha256: sha256(bytes),
         commands_sha256: sha256(commands_json(commands)),
         setup: setup,
         checks: checks,
         git: git
       }}
    end
  end

  @doc "Checks whether a project is ready for read-only shaping or Build admission."
  @spec check_ready(t(), :shape | :build) :: :ok | {:error, String.t()}
  def check_ready(%{root: root}, :shape) do
    case git_state(root) do
      {:ok, _git} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def check_ready(%{root: root}, :build) do
    with {:ok, git} <- git_state(root),
         :ok <- build_branch(git.branch),
         :ok <- main_worktree(root),
         :ok <- build_head(git.head) do
      build_clean(git.clean?)
    end
  end

  def check_ready(_project, mode),
    do: {:error, "unsupported project admission mode: #{inspect(mode)}"}

  defp canonical_engine(engine_root) do
    case canonical_directory(engine_root, "engine") do
      {:ok, root} ->
        if File.regular?(Path.join(root, "mix.exs")),
          do: {:ok, root},
          else: {:error, "engine checkout is missing mix.exs: #{root}"}

      error ->
        error
    end
  end

  defp git_root(project_root) do
    with {:ok, input} <- canonical_directory(project_root, "project"),
         {:ok, output} <- git(input, ["rev-parse", "--show-toplevel"], "project") do
      root = output |> String.trim_trailing("\n") |> String.trim_trailing("\r")
      canonical = Kogen.ProjectScope.canonical(root)

      if File.dir?(canonical),
        do: {:ok, canonical},
        else: {:error, "Git returned an invalid project root: #{inspect(root)}"}
    else
      {:error, {:not_git, path}} ->
        {:error, "project is not a Git checkout: #{path}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical_directory(path, label) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %{type: :directory}} ->
        canonical = Kogen.ProjectScope.canonical(expanded)

        if File.dir?(canonical),
          do: {:ok, canonical},
          else: {:error, "#{label} directory is unavailable: #{expanded}"}

      {:ok, _other} ->
        {:error, "#{label} path must be a directory: #{expanded}"}

      {:error, reason} ->
        {:error, "cannot open #{label} directory #{expanded}: #{:file.format_error(reason)}"}
    end
  end

  defp read_project_config(root) do
    config_path = Path.join(root, @config_relative)
    kogen_dir = Path.join(root, ".kogen")

    with {:ok, %{type: :directory}} <- File.lstat(kogen_dir),
         {:ok, %{type: :regular}} <- File.lstat(config_path),
         {:ok, bytes} <- File.read(config_path) do
      {:ok, config_path, bytes}
    else
      {:error, :enoent} ->
        {:error, "project config is missing: #{Path.join(root, @config_relative)}"}

      {:ok, %{type: :symlink}} ->
        {:error,
         "project config paths must not be symlinks: #{Path.join(root, @config_relative)}"}

      _ ->
        {:error, "project config is not a regular file: #{Path.join(root, @config_relative)}"}
    end
  end

  defp decode_config(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, config} when is_map(config) -> {:ok, normalize_keys(config)}
      {:ok, _other} -> {:error, "project.yaml must contain a mapping"}
      {:error, error} -> {:error, "invalid project.yaml: #{Exception.message(error)}"}
    end
  end

  defp validate_config(config) do
    with :ok <- only_keys(config, ["setup", "checks"], "project.yaml"),
         {:ok, setup} <- validate_setup(Map.get(config, "setup")),
         {:ok, checks} <- validate_checks(Map.get(config, "checks")) do
      {:ok, setup, checks}
    end
  end

  defp validate_setup(nil), do: {:ok, nil}

  defp validate_setup(setup) when is_map(setup) do
    setup = normalize_keys(setup)

    with :ok <- only_keys(setup, @setup_keys, "setup"),
         {:ok, argv} <- validate_argv(Map.get(setup, "argv"), "setup.argv"),
         {:ok, requires} <- validate_requires(Map.get(setup, "requires")) do
      {:ok, %{"argv" => argv, "requires" => requires}}
    end
  end

  defp validate_setup(_setup), do: {:error, "setup must be a mapping with argv and requires"}

  defp validate_checks(checks) when is_list(checks) and checks != [] do
    Enum.reduce_while(checks, {:ok, [], MapSet.new()}, fn check, {:ok, acc, names} ->
      case normalize_check(check, names) do
        {:ok, checked, name} ->
          {:cont, {:ok, [checked | acc], MapSet.put(names, name)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checks, _names} -> {:ok, Enum.reverse(checks)}
      error -> error
    end
  end

  defp validate_checks(_checks), do: {:error, "checks must be a nonempty list"}

  defp normalize_check(check, names) when is_map(check) do
    check = normalize_keys(check)

    with :ok <- only_keys(check, @check_keys, "checks entry"),
         {:ok, name} <- nonblank_string(Map.get(check, "name"), "checks.name"),
         false <- MapSet.member?(names, name),
         {:ok, argv} <- validate_argv(Map.get(check, "argv"), "checks.#{name}.argv") do
      {:ok, %{"name" => name, "argv" => argv}, name}
    else
      true -> {:error, "check names must be unique"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_check(_check, _names), do: {:error, "checks entries must be mappings"}

  defp validate_requires(requires) when is_list(requires) do
    Enum.reduce_while(requires, {:ok, []}, fn requirement, {:ok, acc} ->
      case validate_requirement(requirement) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_requires(_requires), do: {:error, "setup.requires must be a list"}

  defp validate_requirement(requirement) when is_map(requirement) do
    requirement = normalize_keys(requirement)

    case Map.to_list(requirement) do
      [{"path", path}] ->
        with {:ok, path} <- nonblank_string(path, "setup.requires.path") do
          {:ok, %{"kind" => "path", "value" => path}}
        end

      [{"executable", executable}] ->
        with {:ok, executable} <- nonblank_string(executable, "setup.requires.executable"),
             false <- String.contains?(executable, ["/", <<0>>]) do
          {:ok, %{"kind" => "executable", "value" => executable}}
        else
          true -> {:error, "setup.requires.executable must be a command name without a path"}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "each setup.requires entry must contain exactly one path or executable"}
    end
  end

  defp validate_requirement(_requirement),
    do: {:error, "each setup.requires entry must be a mapping"}

  defp validate_argv(argv, label) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, <<0>>))) and
         String.trim(hd(argv)) != "" do
      {:ok, argv}
    else
      {:error, "#{label} must be a nonempty argv list of strings without NUL bytes"}
    end
  end

  defp validate_argv(_argv, label),
    do: {:error, "#{label} must be a nonempty argv list of strings"}

  defp nonblank_string(value, label) when is_binary(value) do
    if String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, "#{label} must be a nonblank string"}
  end

  defp nonblank_string(_value, label), do: {:error, "#{label} must be a nonblank string"}

  defp only_keys(map, allowed, label) do
    unknown = Map.keys(map) -- allowed

    if unknown == [],
      do: :ok,
      else: {:error, "#{label} has unsupported keys: #{Enum.join(unknown, ", ")}"}
  end

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} ->
      normalized = if is_binary(key), do: key, else: inspect(key)
      {normalized, value}
    end)
  end

  defp resolve_setup(nil, _root), do: {:ok, nil}

  defp resolve_setup(%{"argv" => argv, "requires" => requires}, root) do
    case resolve_requires(requires, root) do
      {:ok, resolved_requires, []} ->
        {:ok,
         %{
           "argv" => argv,
           "command" => render_argv(argv),
           "requires" => resolved_requires
         }}

      {:ok, _resolved_requires, missing} ->
        {:error, missing_prerequisites(missing, argv)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_requires(requires, root) do
    Enum.reduce_while(requires, {:ok, [], []}, fn requirement, {:ok, acc, missing} ->
      case resolve_requirement(requirement, root) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc], missing}}
        {:missing, label, resolved} -> {:cont, {:ok, [resolved | acc], [label | missing]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved, []} -> {:ok, Enum.reverse(resolved), []}
      {:ok, resolved, missing} -> {:ok, Enum.reverse(resolved), Enum.reverse(missing)}
      error -> error
    end
  end

  defp resolve_requirement(%{"kind" => "executable", "value" => name}, _root) do
    case System.find_executable(name) do
      nil ->
        {:missing, "executable #{inspect(name)}",
         %{"kind" => "executable", "value" => name, "resolved" => nil}}

      path ->
        resolved = Kogen.ProjectScope.canonical(path)
        {:ok, %{"kind" => "executable", "value" => name, "resolved" => resolved}}
    end
  end

  defp resolve_requirement(%{"kind" => "path", "value" => value}, root) do
    path = if Path.type(value) == :absolute, do: value, else: Path.expand(value, root)
    canonical = Kogen.ProjectScope.canonical(path)

    if Path.type(value) != :absolute and not within?(canonical, root) do
      {:error, "relative setup path escapes the project: #{value}"}
    else
      result = %{"kind" => "path", "value" => value, "resolved" => canonical}
      if File.exists?(path), do: {:ok, result}, else: {:missing, "path #{inspect(value)}", result}
    end
  end

  defp missing_prerequisites(missing, setup_argv) do
    command = render_argv(setup_argv)
    "missing project prerequisite(s): #{Enum.join(missing, ", ")}; setup command: #{command}"
  end

  defp resolve_checks(checks, root, setup) do
    Enum.reduce_while(checks, {:ok, []}, fn check, {:ok, acc} ->
      case resolve_argv(check["argv"], root, "check #{inspect(check["name"])}") do
        {:ok, argv} ->
          resolved = %{"name" => check["name"], "argv" => argv}
          {:cont, {:ok, [resolved | acc]}}

        {:error, reason} ->
          {:halt, {:error, attach_setup(reason, check_setup_argv(setup))}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp check_setup_argv(%{"argv" => argv}), do: argv
  defp check_setup_argv(_setup), do: nil

  defp attach_setup(reason, nil), do: reason

  defp attach_setup(reason, setup_argv),
    do: "#{reason}; setup command: #{render_argv(setup_argv)}"

  defp resolve_argv([executable | args], root, label) do
    case resolve_executable(executable, root) do
      {:ok, resolved} -> {:ok, [resolved | args]}
      {:error, reason} -> {:error, "#{label} executable is unavailable: #{reason}"}
    end
  end

  defp resolve_executable(executable, root) do
    cond do
      Path.type(executable) == :absolute ->
        executable_file(executable)

      String.contains?(executable, "/") ->
        path = executable |> Path.expand(root) |> Kogen.ProjectScope.canonical()

        if within?(path, root) do
          executable_file(path)
        else
          {:error, "relative executable path escapes the project: #{inspect(executable)}"}
        end

      true ->
        case System.find_executable(executable) do
          nil -> {:error, inspect(executable)}
          path -> {:ok, Kogen.ProjectScope.canonical(path)}
        end
    end
  end

  defp executable_file(path) do
    canonical = Kogen.ProjectScope.canonical(path)

    case File.stat(canonical) do
      {:ok, %{type: :regular, mode: mode}} when band(mode, 0o111) != 0 -> {:ok, canonical}
      _ -> {:error, inspect(path)}
    end
  end

  defp git_root_status(root) do
    with {:ok, branch_output} <-
           git_optional(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         {:ok, head_output} <- git_optional(root, ["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, status_output} <-
           git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], "project") do
      {:ok,
       %{
         branch:
           if(branch_output == "", do: nil, else: String.trim_trailing(branch_output, "\n")),
         head: if(head_output == "", do: nil, else: String.trim_trailing(head_output, "\n")),
         clean?: status_output == ""
       }}
    end
  end

  defp git_state(root), do: git_root_status(root)

  defp git_optional(root, args) do
    case System.cmd("git", ["-C", root] ++ args,
           stderr_to_stdout: true,
           env: git_environment()
         ) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:ok, ""}
    end
  rescue
    error -> {:error, "could not inspect project Git state: #{Exception.message(error)}"}
  end

  defp git(root, args, label) do
    case System.cmd("git", ["-C", root] ++ args,
           stderr_to_stdout: true,
           env: git_environment()
         ) do
      {output, 0} ->
        {:ok, output}

      {_output, 128} when hd(args) == "rev-parse" ->
        {:error, {:not_git, root}}

      {output, status} ->
        {:error, "Git could not inspect #{label} (exit #{status}): #{String.trim(output)}"}
    end
  rescue
    error -> {:error, "could not run Git for #{label}: #{Exception.message(error)}"}
  end

  defp git_environment do
    case System.cmd("git", ["rev-parse", "--local-env-vars"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&{&1, nil})

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp build_branch(nil),
    do: {:error, "Build admission requires an attached branch; HEAD is detached"}

  defp build_branch(_branch), do: :ok

  defp main_worktree(root) do
    with {:ok, dir} <- git(root, ["rev-parse", "--path-format=absolute", "--git-dir"], "project"),
         {:ok, common} <-
           git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], "project") do
      if Kogen.ProjectScope.canonical(String.trim(dir)) ==
           Kogen.ProjectScope.canonical(String.trim(common)),
         do: :ok,
         else: {:error, "Build admission requires a main worktree, not a linked worktree"}
    end
  end

  defp build_head(nil), do: {:error, "Build admission requires a committed HEAD"}
  defp build_head(_head), do: :ok

  defp build_clean(true), do: :ok
  defp build_clean(false), do: {:error, "Build admission requires a clean project checkout"}

  defp within?(path, root) do
    path_parts = Path.split(Path.expand(path))
    root_parts = Path.split(Path.expand(root))
    Enum.take(path_parts, length(root_parts)) == root_parts
  end

  defp commands_json(%{setup: setup, checks: checks}) do
    setup_json =
      if setup do
        Jason.OrderedObject.new([
          {"argv", setup["argv"]},
          {"command", setup["command"]},
          {"requires", Enum.map(setup["requires"], &ordered_requirement/1)}
        ])
      else
        nil
      end

    check_json =
      Enum.map(checks, fn check ->
        Jason.OrderedObject.new([{"name", check["name"]}, {"argv", check["argv"]}])
      end)

    Jason.OrderedObject.new([{"setup", setup_json}, {"checks", check_json}])
    |> Jason.encode_to_iodata!()
    |> IO.iodata_to_binary()
  end

  defp ordered_requirement(requirement) do
    Jason.OrderedObject.new(
      Enum.map(["kind", "value", "resolved"], fn key -> {key, requirement[key]} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  defp render_argv(argv), do: Enum.map_join(argv, " ", &shell_quote/1)

  defp shell_quote(value) do
    if Regex.match?(~r|^[A-Za-z0-9_./:@%+=,-]+$|, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
