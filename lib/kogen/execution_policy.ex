defmodule Kogen.ExecutionPolicy do
  @moduledoc "Renders the shared execution policy and configured profiles for each root role."
  use Boundary, deps: []

  @path "priv/kogen/prompts/execution-policy.md"
  @roles %{"shaping" => :shaping, "developer" => :developer, "reviewer" => :reviewer}
  @helpers [{:scout, "explorer"}, {:worker, "worker"}, {:expert, "default"}]

  @doc "Expands the maintained policy with explicit current root and helper profiles."
  def render(config, role) do
    root = Map.fetch!(config, Map.fetch!(@roles, role))

    helpers =
      Enum.map_join(@helpers, "\n", fn {label, kind} ->
        profile = Map.fetch!(config.helpers, label)
        "- **#{label}:** `#{profile.model}` at `#{profile.effort}`; native kind `#{kind}`."
      end)

    File.read!(@path)
    |> String.replace(
      "{{root_profile}}",
      "Configured root (#{role}): `#{root.model}` at `#{root.effort}`."
    )
    |> String.replace("{{helper_profiles}}", helpers)
  end
end
