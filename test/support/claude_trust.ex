defmodule Kogen.LiveClaudeTrust do
  @moduledoc false

  # Interactive Claude Code asks once per new repository root whether to trust
  # it (default: No, exit), even with --dangerously-skip-permissions. Kogen
  # never answers that dialog. The live Shape test pre-trusts only the fixture
  # repository it created, through the documented
  # `projects[<repo root>].hasTrustDialogAccepted` setting in the selected Kogen
  # config dir's `.claude.json`, and removes that entry when it finishes.
  # Every other key in the file is preserved byte-for-byte in meaning.

  @doc "Pre-trusts exactly `fixture`'s repository root in its selected Kogen scope."
  def grant!(fixture) do
    root = repository_root!(fixture)
    path = config_path!(fixture)

    update!(path, fn config ->
      projects = Map.get(config, "projects", %{})
      entry = Map.get(projects, root, %{})

      Map.put(
        config,
        "projects",
        Map.put(projects, root, Map.put(entry, "hasTrustDialogAccepted", true))
      )
    end)

    %{path: path, root: root}
  end

  @doc "Removes the fixture's project entry again."
  def revoke!(%{path: path, root: root}) do
    if File.regular?(path), do: update!(path, &forget(&1, root))
    :ok
  end

  defp forget(%{"projects" => projects} = config, root) when is_map(projects),
    do: Map.put(config, "projects", Map.delete(projects, root))

  defp forget(config, _root), do: config

  defp repository_root!(fixture) do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], cd: fixture)
    String.trim(root)
  end

  defp config_path!(fixture) do
    {:ok, %{path: scope}} = Kogen.ClaudeCode.effective_scope(fixture)

    unless File.dir?(scope),
      do: raise(ArgumentError, "selected Kogen Claude Code scope is missing: #{scope}")

    Path.join(scope, ".claude.json")
  end

  defp update!(path, function) do
    current =
      case File.read(path) do
        {:ok, bytes} -> Jason.decode!(bytes)
        {:error, :enoent} -> %{}
      end

    temporary = path <> ".kogen-live-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(function.(current), pretty: true), [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end
