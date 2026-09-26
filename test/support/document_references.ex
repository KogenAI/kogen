defmodule Kogen.Test.DocumentReferences do
  @moduledoc """
  Behavior-checking helpers for README and role-prompt tests
  (scenario `docs-and-prompts-checked-by-meaning`).

  These tests check what code or a role depends on, not the exact wording
  of a document: every backticked repository path a document names actually
  exists (skipping placeholders, globs and runtime/ignored locations), and
  every `Module.function/arity` a document names is actually exported.
  """

  # The same volatile/ignored locations `Kogen.Build.GuardedPaths` treats as
  # not part of the frozen Candidate topology. Kept in sync by hand: this
  # module cannot depend on GuardedPaths (a Boundary-restricted lib module)
  # from test/support.
  @volatile_prefixes ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions _build deps cover .elixir_ls)

  @allowed_prefixes ~w(lib/ priv/ scripts/ test/ .codex/ .claude/)
  @allowed_exact ~w(Makefile mix.exs mise.toml)

  @doc """
  Every path named in backticks in `text` that looks like a repository path:
  starts with one of `lib/ priv/ scripts/ test/ .codex/ .claude/`, or is
  exactly `Makefile`, `mix.exs` or `mise.toml`. Paths with a `<placeholder>`
  segment or a glob (`*`) are excluded, and so are volatile/runtime/ignored
  locations.
  """
  @spec repo_paths(String.t()) :: [String.t()]
  def repo_paths(text) when is_binary(text) do
    ~r/`([^`\s]+)`/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.filter(&candidate_repo_path?/1)
    |> Enum.uniq()
  end

  defp candidate_repo_path?(path) do
    (Enum.any?(@allowed_prefixes, &String.starts_with?(path, &1)) or path in @allowed_exact) and
      not String.contains?(path, "<") and
      not String.contains?(path, "*") and
      not volatile?(path)
  end

  defp volatile?(path) do
    Enum.any?(@volatile_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  @doc """
  Repo-relative paths named in `text` that do not exist under `root` (as a
  regular file or a directory). Reads the file system, not Git, so it holds
  in the gitless `cold-offline` copy too.
  """
  @spec missing_paths(Path.t(), String.t()) :: [String.t()]
  def missing_paths(root, text) do
    text
    |> repo_paths()
    |> Enum.reject(fn path ->
      absolute = Path.join(root, path)
      File.regular?(absolute) or File.dir?(absolute)
    end)
  end

  @doc """
  Every `Module.function/arity` reference named in `text`, as
  `{module_string, function_atom, arity}`. `module_string` may be a short
  name (for example `VerificationPlan.load/1`), not a full `Kogen.*` path.
  """
  @spec function_references(String.t()) :: [{String.t(), atom(), non_neg_integer()}]
  def function_references(text) when is_binary(text) do
    ~r/`?([A-Z][A-Za-z0-9_.]*)\.([a-z_][A-Za-z0-9_?!]*)\/(\d+)`?/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [module, function, arity] ->
      {module, String.to_atom(function), String.to_integer(arity)}
    end)
    |> Enum.uniq()
  end

  @doc """
  References from `function_references/1` that do not resolve to exactly
  one exported function on a real `Kogen.*` module. A short module name
  (no dot, or a dotted suffix such as `Build.VerificationPlan`) must match
  exactly one loaded `Kogen.*` module by its trailing segments.
  """
  @spec unresolved_functions(String.t()) :: [{String.t(), atom(), non_neg_integer()}]
  def unresolved_functions(text) do
    text
    |> function_references()
    |> Enum.reject(&resolves?/1)
  end

  defp resolves?({module_suffix, function, arity}) do
    case matching_modules(module_suffix) do
      [module] -> function_exported?(module, function, arity)
      _ -> false
    end
  end

  defp matching_modules(module_suffix) do
    suffix_segments = String.split(module_suffix, ".")

    kogen_modules()
    |> Enum.filter(fn module ->
      ends_with_segments?(Module.split(module), suffix_segments)
    end)
  end

  defp ends_with_segments?(module_segments, suffix_segments) do
    count = length(suffix_segments)
    count > 0 and Enum.take(module_segments, -count) == suffix_segments
  end

  defp kogen_modules do
    (Application.spec(:kogen, :modules) || [])
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and
        match?(["Kogen" | _], Module.split(module))
    end)
  end

  @doc "Whether every `{{placeholder}}` in `keys` appears literally in `template`."
  @spec placeholders_present?(String.t(), [String.t()]) :: boolean()
  def placeholders_present?(template, keys) do
    Enum.all?(keys, &String.contains?(template, "{{#{&1}}}"))
  end
end
