defmodule Kogen.Config do
  @moduledoc "`.kogen/project.yaml`: the project's commands, protected paths and models (SET-7, SET-8)."
  alias Kogen.{Error, Yaml}

  defstruct setup: [],
            fix: [],
            checks: [],
            acceptance_run: nil,
            steps_dir: nil,
            protect: [],
            models: %{},
            shape_workers: %{enabled: false}

  @path ".kogen/project.yaml"
  def path, do: @path

  # The one owner of the per-role defaults (SET-8); the template below is derived from it.
  @default_models %{
    "shape" => %{model: "gpt-6.1-sol", effort: "high"},
    "build" => %{model: "gpt-6.1-sol", effort: "medium"},
    "review" => %{model: "gpt-6.1-sol", effort: "high"}
  }

  @template """
  version: 1
  commands:
    setup: []          # run before readiness dry runs and before each Build
    fix: []            # deterministic fixers, run once after each builder round
    checks: []         # project checks, e.g. {name: test, run: "mix test"}
    acceptance:
      run: null        # the acceptance command (VER-3)
      steps_dir: null  # where shaping writes step-definition files
  protect: []          # check configuration the Build must not change, e.g. .credo.exs
  models:
  #{for role <- ~w(shape build review), into: "", do: "  #{role}:\n    model: #{@default_models[role].model}\n    effort: #{@default_models[role].effort}\n"}\
  """
  def template, do: @template

  @doc """
  The template with the commands `init` kept (SET-2): `setup`, `fix` and `protect` lists of
  strings, `checks` `%{name, run}` entries, `acceptance` nil or `{run, steps_dir}`.
  """
  def render(%{setup: setup, fix: fix, checks: checks, protect: protect, acceptance: acc}) do
    template_line = fn key ->
      Enum.find(String.split(@template, "\n"), &String.starts_with?(&1, key))
    end

    list = fn key, items, item ->
      if items == [],
        do: [template_line.(key)],
        else: [String.trim_trailing(key)] ++ Enum.map(items, &("    - " <> item.(&1)))
    end

    commands =
      list.("  setup:", setup, &yaml_quote/1) ++
        list.("  fix:", fix, &yaml_quote/1) ++
        list.("  checks:", checks, &"name: #{&1.name}\n      run: #{yaml_quote(&1.run)}") ++
        ["  acceptance:"] ++
        if(acc,
          do: ["    run: " <> yaml_quote(acc.run), "    steps_dir: " <> yaml_quote(acc.steps_dir)],
          else: [template_line.("    run:"), template_line.("    steps_dir:")]
        )

    protect =
      if protect == [],
        do: template_line.("protect:"),
        else: "protect:\n" <> Enum.map_join(protect, "\n", &("  - " <> yaml_quote(&1)))

    [models | _] = @template |> String.split("models:\n") |> tl()

    Enum.join(["version: 1", "commands:"] ++ commands ++ [protect, "models:"], "\n") <>
      "\n" <> models
  end

  # A YAML single-quoted scalar: the only escape is '' for '.
  defp yaml_quote(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  def default_models, do: @default_models

  @doc "Loads and validates the configuration of an initialized project, or raises SET-4 / SHP-2 errors."
  def load!(root) do
    file = Path.join(root, @path)

    case File.read(file) do
      {:error, _} ->
        Error.raise!(
          "environment",
          "not_initialized",
          "#{root} has no .kogen/project.yaml; run kogen init",
          3
        )

      {:ok, text} ->
        parse!(text, file)
    end
  end

  def parse!(text, file) do
    {config, problems} =
      case Yaml.parse(text) do
        {:ok, {:map, _, pairs} = node} ->
          if not Enum.any?(pairs, &match?({"version", _, _}, &1)),
            do:
              Error.raise!(
                "environment",
                "old_kogen_config",
                ".kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init",
                3
              )

          validate(node)

        {:ok, node} ->
          validate(node)

        {:error, problems} ->
          {nil, problems}
      end

    if problems != [] do
      lines = problems |> Enum.sort() |> Enum.map(fn {n, msg} -> "line #{n}: #{msg}" end)
      Error.raise!("environment", "project_config_invalid", file, 3, lines)
    end

    config
  end

  defp validate({:map, _, pairs}) do
    {problems, acc} =
      Enum.reduce(pairs, {[], %__MODULE__{models: @default_models}}, fn {key, line, node},
                                                                        {probs, c} ->
        case key do
          "version" ->
            if match?({:scalar, _, "1", :plain}, node),
              do: {probs, c},
              else: {[{line, "version must be 1"} | probs], c}

          "commands" ->
            {p, c} = commands(node, c)
            {p ++ probs, c}

          "protect" ->
            {p, list} = strings(node, "protect")
            {p ++ probs, %{c | protect: list}}

          "shape_workers" ->
            {p, workers} = workers(node)
            {p ++ probs, %{c | shape_workers: workers}}

          "models" ->
            {p, models} = models(node)
            {p ++ probs, %{c | models: models}}

          _ ->
            {[{line, "unknown key #{key}"} | probs], c}
        end
      end)

    problems =
      if List.keymember?(pairs, "version", 0),
        do: problems,
        else: [{1, "version is required"} | problems]

    {acc, problems}
  end

  defp validate(node), do: {nil, [{line(node), "the file must be a mapping"}]}

  defp commands({:map, _, pairs}, c) do
    Enum.reduce(pairs, {[], c}, fn {key, line, node}, {probs, c} ->
      case key do
        "setup" ->
          strings(node, "commands.setup") |> then(fn {p, l} -> {p ++ probs, %{c | setup: l}} end)

        "fix" ->
          strings(node, "commands.fix") |> then(fn {p, l} -> {p ++ probs, %{c | fix: l}} end)

        "checks" ->
          checks(node) |> then(fn {p, l} -> {p ++ probs, %{c | checks: l}} end)

        "acceptance" ->
          acceptance(node, c) |> then(fn {p, c} -> {p ++ probs, c} end)

        _ ->
          {[{line, "unknown key #{key}"} | probs], c}
      end
    end)
  end

  defp commands(node, c), do: {[{line(node), "commands must be a mapping"}], c}

  defp acceptance({:map, _, pairs}, c) do
    Enum.reduce(pairs, {[], c}, fn {key, line, node}, {probs, c} ->
      cond do
        key not in ["run", "steps_dir"] ->
          {[{line, "unknown key #{key}"} | probs], c}

        not match?({:scalar, _, nil, _}, node) and
            not (match?({:scalar, _, _, _}, node) and string?(node)) ->
          {[{line, "commands.acceptance.#{key} must be a string or null"} | probs], c}

        key == "run" ->
          {probs, %{c | acceptance_run: elem(node, 2)}}

        true ->
          {probs, %{c | steps_dir: elem(node, 2) && String.trim_trailing(elem(node, 2), "/")}}
      end
    end)
  end

  defp acceptance(node, c), do: {[{line(node), "commands.acceptance must be a mapping"}], c}

  defp checks({:seq, _, items}) do
    {probs, list} =
      Enum.reduce(items, {[], []}, fn item, {probs, list} ->
        case item do
          {:map, line, pairs} ->
            unknown =
              for {k, l, _} <- pairs, k not in ["name", "run"], do: {l, "unknown key #{k}"}

            name = string_at(pairs, "name")
            run = string_at(pairs, "run")

            cond do
              unknown != [] ->
                {unknown ++ probs, list}

              name == nil or run == nil ->
                {[{line, "a check needs a name and a run string"} | probs], list}

              name in ["acceptance", "model"] ->
                {[{line, "check name #{name} is reserved"} | probs], list}

              not Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) ->
                {[{line, "check name #{name} must be lowercase"} | probs], list}

              List.keymember?(list, name, 0) ->
                {[{line, "check name #{name} is used twice"} | probs], list}

              true ->
                {probs, [{name, run} | list]}
            end

          _ ->
            {[{line(item), "a check must be {name, run}"} | probs], list}
        end
      end)

    {probs, Enum.reverse(list)}
  end

  defp checks(node), do: {[{line(node), "commands.checks must be a list"}], []}

  defp models({:map, _, pairs}) do
    # Older project files may retain a planner model. It is ignored: building
    # starts directly and never issues a separate planning request.
    pairs = Enum.reject(pairs, fn {role, _, _} -> role == "plan" end)

    Enum.reduce(pairs, {[], @default_models}, fn {role, line, node}, {probs, models} ->
      with true <- Map.has_key?(@default_models, role),
           {:map, _, kv} <- node,
           [] <- for({k, _, _} <- kv, k not in ["model", "effort", "provider"], do: k),
           m when is_binary(m) <- string_at(kv, "model"),
           e when is_binary(e) <- string_at(kv, "effort") do
        role_config(kv, "models.#{role}", line, m, e, probs, models, role)
      else
        false -> {[{line, "unknown key #{role}"} | probs], models}
        _ -> {[{line, "models.#{role} must be {model, effort}"} | probs], models}
      end
    end)
  end

  defp models(node), do: {[{line(node), "models must be a mapping"}], @default_models}

  defp workers({:map, line, pairs}) do
    {problems, result} =
      Enum.reduce(pairs, {[], %{enabled: false}}, fn
        {"enabled", _, {:scalar, _, value, :plain}}, {p, w}
        when value in [true, false, "true", "false"] ->
          {p, Map.put(w, :enabled, value in [true, "true"])}

        {"enabled", l, _}, {p, w} ->
          {[{l, "shape_workers.enabled must be a Boolean"} | p], w}

        {role, l, node}, {p, w} when role in ~w(read probe draft) ->
          case node do
            {:map, _, kv} ->
              m = string_at(kv, "model")
              e = string_at(kv, "effort")

              if is_binary(m) and String.trim(m) != "" and is_binary(e) and String.trim(e) != "" and
                   Enum.all?(kv, fn {k, _, _} -> k in ~w(model effort provider) end),
                 do: role_config(kv, "shape_workers.#{role}", l, m, e, p, w, role),
                 else: {[{l, "shape_workers.#{role} must be {model, effort} strings"} | p], w}

            _ ->
              {[{l, "shape_workers.#{role} must be {model, effort} strings"} | p], w}
          end

        {key, l, _}, {p, w} ->
          {[{l, "unknown key #{key}"} | p], w}
      end)

    missing =
      if result.enabled,
        do: Enum.reject(~w(read probe draft), &Map.has_key?(result, &1)),
        else: []

    {problems ++
       Enum.map(missing, &{line, "shape_workers.#{&1} requires explicit model and effort"}),
     result}
  end

  defp workers(node), do: {[{line(node), "shape_workers must be a mapping"}], %{enabled: false}}

  defp role_config(kv, path, line, m, e, problems, roles, role) do
    provider = string_at(kv, "provider")
    present = Enum.any?(kv, fn {k, _, _} -> k == "provider" end)

    cond do
      present and provider not in ["chatgpt", "supergrok", "opencode-go"] ->
        {[{line, "#{path}.provider must be chatgpt, supergrok or opencode-go"} | problems], roles}

      provider == "opencode-go" and (m != "kimi-k3" or e not in ~w(default high)) ->
        {[
           {line, "#{path}: opencode-go supports model kimi-k3 with effort default or high"}
           | problems
         ], roles}

      provider == "supergrok" and (m != "grok-4.7" or e not in ~w(low medium high xhigh)) ->
        {[
           {line,
            "#{path}: supergrok supports model grok-4.7 with effort low, medium, high or xhigh"}
           | problems
         ], roles}

      true ->
        value = %{model: m, effort: e}
        value = if present, do: Map.put(value, :provider, provider), else: value
        {problems, Map.put(roles, role, value)}
    end
  end

  defp strings({:seq, _, items}, name) do
    Enum.reduce(items, {[], []}, fn
      {:scalar, _, v, _} = node, {p, l} when is_binary(v) ->
        if string?(node),
          do: {p, l ++ [v]},
          else: {[{line(node), "#{name} entries must be strings"} | p], l}

      node, {p, l} ->
        {[{line(node), "#{name} entries must be strings"} | p], l}
    end)
  end

  defp strings(node, name), do: {[{line(node), "#{name} must be a list"}], []}

  defp string_at(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {_, _, {:scalar, _, v, _} = node} when is_binary(v) -> if string?(node), do: v
      _ -> nil
    end
  end

  defp line(node), do: elem(node, 1)

  # A plain true, false or number is not a string; quote it to use it as one.
  defp string?({:scalar, _, _, :quoted}), do: true

  defp string?({:scalar, _, v, :plain}),
    do:
      not Regex.match?(
        ~r/^(true|false|True|False|TRUE|FALSE|[-+]?[0-9][0-9._]*(e[-+]?[0-9]+)?)$/,
        v
      )

  @doc "Every configured command with its name, in the order Kogen runs them (SET-8)."
  def named_commands(%__MODULE__{} = c) do
    Enum.with_index(c.setup, 1)
    |> Enum.map(fn {cmd, i} -> {"setup-#{i}", cmd} end)
    |> Kernel.++(Enum.with_index(c.fix, 1) |> Enum.map(fn {cmd, i} -> {"fix-#{i}", cmd} end))
    |> Kernel.++(c.checks)
    |> Kernel.++(if c.acceptance_run, do: [{"acceptance", c.acceptance_run}], else: [])
  end
end
