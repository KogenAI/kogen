defmodule CodegenTestHarness.RoleResolver do
  @moduledoc """
  Resolves a `{role, harness}` pair to the model/effort inputs an
  orchestration loop needs to invoke that role.

  Foundational primitive only.

  `resolve_role/2` reads model/effort from `templates/generator/config.yaml`
  (source of truth for role → model/effort mapping). Agent identity (system
  prompt, allowed tools) is NOT resolved here — the claude_code loop invokes
  roles natively via `claude --agent <role>`, which resolves prompt + tools
  from the installed `~/.claude/agents/<role>.md` itself.

  Every missing/malformed input raises loud — no silent defaults.
  """

  @type role_harness :: String.t()
  @type resolve_opts :: keyword()

  @config_yaml Path.expand("../../../templates/generator/config.yaml", __DIR__)

  @doc """
  Resolves `role` for `harness` using the default `config.yaml` path.

  See `resolve_role/3` for the opts form.
  """
  @spec resolve_role(role_harness(), role_harness()) :: {String.t(), String.t()}
  def resolve_role(role, harness) do
    resolve_role(role, harness, [])
  end

  @doc """
  Resolves `role` for `harness`, returning `{model, effort}`.

  `opts`: none currently defined (kept for call-site symmetry with the
  overload above and future extension).

  Raises if the role is unknown in `config.yaml`.
  """
  @spec resolve_role(role_harness(), role_harness(), resolve_opts()) :: {String.t(), String.t()}
  def resolve_role(role, harness, _opts) do
    # config.yaml keys on the SHORT harness name ("claude"), but the
    # loop/codegen-call canonical harness is "claude_code". Normalize.
    config_harness = normalize_harness(harness)

    model = config_yaml_read!(".harness.#{role}.#{config_harness}.model")
    effort = config_yaml_read!(".harness.#{role}.#{config_harness}.effort")

    {model, effort}
  end

  # Maps the canonical loop/codegen-call harness name to the short name that
  # config.yaml keys on.
  defp normalize_harness("claude_code"), do: "claude"
  defp normalize_harness(other), do: other

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
end
