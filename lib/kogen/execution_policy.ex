defmodule Kogen.ExecutionPolicy do
  @moduledoc """
  Renders the shared execution policy and configured profiles for each root role.

  Each role sees its own assigned harness: its native helpers, and the Expert
  either as a native helper on the same harness or, when the route assigns the
  Expert to another harness, only through `mix kogen.expert`.
  """
  use Boundary, deps: [Kogen.Intent]

  @path "priv/kogen/prompts/execution-policy.md"
  @roles %{
    "shaping" => :shaping,
    "developer" => :developer,
    "reviewer" => :reviewer,
    "expert" => :expert
  }
  @helpers [{:scout, "explorer"}, {:worker, "worker"}, {:expert, "default"}]
  @harness_names %{"claude" => "Claude Code", "codex" => "Codex"}
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
    role_key = Map.fetch!(@roles, role)
    root = Map.fetch!(config, role_key)
    view = Kogen.Intent.role_config(config, role_key)
    harness = Map.fetch!(view, :harness)
    delegation!(harness)

    helpers =
      @helpers
      |> Enum.flat_map(fn {label, kind} -> helper_line(config, view, role_key, label, kind) end)
      |> Enum.join("\n")

    File.read!(@path)
    |> String.replace(
      "{{root_profile}}",
      "Configured root (#{role}): `#{root.model}` at `#{root.effort}`."
    )
    |> String.replace("{{helper_profiles}}", helpers)
    |> routing(harness)
  end

  # The Expert is the uncertainty's last stop: it never delegates to itself.
  defp helper_line(_config, _view, :expert, :expert, _kind), do: []

  defp helper_line(config, view, _role, label, kind) do
    case Map.fetch(view.helpers, label) do
      {:ok, profile} ->
        [
          "- **#{label}:** `#{profile.model}` at `#{profile.effort}`; #{delegation(view.harness, label, kind)}."
        ]

      :error when label == :expert and is_map_key(config, :expert) ->
        [cross_harness_expert(config)]

      :error ->
        []
    end
  end

  # The Expert runs on another harness than this role: Kogen launches it, and
  # no native helper of this role's harness stands in for it.
  defp cross_harness_expert(config) do
    harness = Kogen.Intent.role_harness(config, :expert)

    "- **expert:** `#{config.expert.model}` at `#{config.expert.effort}` on the " <>
      "#{Map.fetch!(@harness_names, harness)} harness, not a native helper of this role. " <>
      "Consult it only by running `mix kogen.expert` with one self-contained question " <>
      "on stdin; Kogen launches it read-only and prints its answer. Never substitute " <>
      "a native helper or another model for it."
  end

  defp delegation!(harness) when harness in ["claude", "codex"], do: :ok

  defp delegation!(harness),
    do: raise(ArgumentError, "unsupported harness: #{inspect(harness)}; expected codex or claude")

  defp delegation("claude", label, _kind), do: "Claude Code agent `kogen-#{label}`"
  defp delegation("codex", _label, kind), do: "native kind `#{kind}`"

  defp routing(text, "claude"), do: String.replace(text, @codex_routing, @claude_routing)
  defp routing(text, "codex"), do: text
end
