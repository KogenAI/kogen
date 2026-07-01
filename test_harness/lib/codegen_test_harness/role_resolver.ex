defmodule CodegenTestHarness.RoleResolver do
  @moduledoc """
  Resolves a `{role, harness}` pair to the concrete inputs an orchestration
  loop needs to invoke that role: system prompt path, model, effort, and
  allowed tools.

  Foundational primitive only — no loop consumes it yet.

  `resolve_role/2` reads model/effort from `templates/generator/config.yaml`
  (source of truth for role → model/effort mapping) and locates the agent's
  rendered `.md` file, preferring the installed `~/.claude/agents/<role>.md`
  and falling back to `templates/generated/claude-code/agents/<role>.md`.
  The agent `.md`'s leading YAML-ish frontmatter block is parsed for its
  `tools:` line, and the body (frontmatter stripped) is written to a fresh
  temp file whose path is returned.

  Every missing/malformed input raises loud — no silent defaults.
  """

  @type role_harness :: String.t()
  @type resolve_opts :: keyword()

  @config_yaml Path.expand("../../../templates/generator/config.yaml", __DIR__)
  @default_agents_dir Path.expand("~/.claude/agents")
  @default_generated_dir Path.expand(
                           "../../../templates/generated/claude-code/agents",
                           __DIR__
                         )

  @doc """
  Resolves `role` for `harness` using default agent/generated directories.

  See `resolve_role/3` for the opts form.
  """
  @spec resolve_role(role_harness(), role_harness()) ::
          {String.t(), String.t(), String.t(), String.t()}
  def resolve_role(role, harness) do
    resolve_role(role, harness, [])
  end

  @doc """
  Resolves `role` for `harness`, returning
  `{system_prompt_path, model, effort, allowed_tools}`.

  `opts`:
  - `:agents_dir` — directory checked first for `<role>.md` (default
    `~/.claude/agents`)
  - `:generated_dir` — fallback directory for `<role>.md` (default
    `templates/generated/claude-code/agents`)

  Raises if the role is unknown in `config.yaml`, if `<role>.md` is not
  found in either directory, or if the agent `.md`'s frontmatter has no
  `tools:` line.
  """
  @spec resolve_role(role_harness(), role_harness(), resolve_opts()) ::
          {String.t(), String.t(), String.t(), String.t()}
  def resolve_role(role, harness, opts) do
    agents_dir = Keyword.get(opts, :agents_dir, @default_agents_dir)
    generated_dir = Keyword.get(opts, :generated_dir, @default_generated_dir)

    model = config_yaml_read!(".harness.#{role}.#{harness}.model")
    effort = config_yaml_read!(".harness.#{role}.#{harness}.effort")

    agent_md_path = locate_agent_md!(role, agents_dir, generated_dir)
    content = File.read!(agent_md_path)

    allowed_tools = parse_tools!(content, agent_md_path)
    body = strip_frontmatter(content)
    system_prompt_path = write_tmp!(body)

    {system_prompt_path, model, effort, allowed_tools}
  end

  # Reads a scalar value from templates/generator/config.yaml using yq.
  # Raises if yq is not on PATH or if the key is missing/empty/null.
  defp config_yaml_read!(key) do
    {value, code} = System.cmd("yq", ["-r", key, @config_yaml], stderr_to_stdout: true)
    value = String.trim(value)

    if code != 0 or value == "" or value == "null" do
      raise "config.yaml key #{key} missing or unreadable (exit=#{code}, value=#{inspect(value)})"
    end

    value
  end

  # Locates <role>.md, preferring agents_dir, falling back to generated_dir.
  # Raises naming both candidate paths if neither exists.
  defp locate_agent_md!(role, agents_dir, generated_dir) do
    installed_path = Path.join(agents_dir, "#{role}.md")
    generated_path = Path.join(generated_dir, "#{role}.md")

    cond do
      File.exists?(installed_path) ->
        installed_path

      File.exists?(generated_path) ->
        generated_path

      true ->
        raise "agent .md for role #{role} not found at #{installed_path} or #{generated_path}"
    end
  end

  # Extracts the tools: line from the leading frontmatter block only.
  # Raises if there is no tools: line in that block.
  defp parse_tools!(content, source_path) do
    frontmatter = leading_frontmatter_block(content)

    case Regex.run(~r/^tools:\s*(.+)$/m, frontmatter) do
      [_, tools] -> String.trim(tools)
      nil -> raise "no tools: line found in frontmatter of #{source_path}"
    end
  end

  # Returns the leading "---\n...\n---" block (without the fences), or the
  # whole content if it does not start with "---".
  defp leading_frontmatter_block(content) do
    case String.split(content, "---\n", parts: 2) do
      ["", rest] ->
        case String.split(rest, "\n---", parts: 2) do
          [frontmatter, _body] -> frontmatter
          [frontmatter] -> frontmatter
        end

      _ ->
        content
    end
  end

  # Removes ONLY the leading "---\n...\n---\n" frontmatter block, preserving
  # all remaining body content including later "---" divider lines. If
  # content does not start with "---", returns it unchanged.
  defp strip_frontmatter(content) do
    case String.split(content, "---\n", parts: 2) do
      ["", rest] ->
        case String.split(rest, "\n---", parts: 2) do
          [_frontmatter, body] -> String.trim_leading(body, "\n")
          [_frontmatter] -> ""
        end

      _ ->
        content
    end
  end

  # Writes content to a fresh temp file and returns its path.
  defp write_tmp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "role_resolver_#{:erlang.unique_integer([:positive])}.txt"
      )

    File.write!(path, content)
    path
  end
end
