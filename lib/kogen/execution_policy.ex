defmodule Kogen.ExecutionPolicy do
  @moduledoc "Renders the shared execution policy and configured profiles for each root role."
  use Boundary, deps: []

  @path "priv/kogen/prompts/execution-policy.md"
  @roles %{"shaping" => :shaping, "developer" => :developer, "reviewer" => :reviewer}
  @helpers [{:scout, "explorer"}, {:worker, "worker"}, {:expert, "default"}]
  @codex_routing """
  The labels scout and expert are
  not native agent-kind enums: use the supported kinds above.\
  """
  @claude_routing """
  Each Claude Code agent above
  already carries its configured model, effort and this role's tool authority;
  delegate only to those agents, never to built-in agents.\
  """

  @doc "Expands the maintained policy with explicit current root and helper profiles."
  def render(config, role) do
    root = Map.fetch!(config, Map.fetch!(@roles, role))
    claude? = Map.get(config, :harness) == "claude"

    helpers =
      Enum.map_join(@helpers, "\n", fn {label, kind} ->
        profile = Map.fetch!(config.helpers, label)

        "- **#{label}:** `#{profile.model}` at `#{profile.effort}`; #{route(claude?, label, kind)}."
      end)

    File.read!(@path)
    |> String.replace(
      "{{root_profile}}",
      "Configured root (#{role}): `#{root.model}` at `#{root.effort}`."
    )
    |> String.replace("{{helper_profiles}}", helpers)
    |> then(&if(claude?, do: String.replace(&1, @codex_routing, @claude_routing), else: &1))
  end

  defp route(true, label, _kind), do: "Claude Code agent `kogen-#{label}`"
  defp route(false, _label, kind), do: "native kind `#{kind}`"
end
